#!/usr/bin/env bash
# Round-trip a dashboard JSON through a throwaway Grafana and report what
# survived. The build does not validate dashboards and bad transformations fail
# silently, so this is the only real gate on a dashboard change.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: test-dashboard.sh <dashboard.json> [--keep] [--port N]

  --keep    leave Grafana running and print its URL instead of stopping it
  --port    port to listen on (default 3999)

Exits non-zero if any panel lost its transformations during conversion.
EOF
  exit 2
}

DASH=""
KEEP=0
PORT=3999

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "unknown flag: $1" >&2; usage ;;
    *) DASH="$1"; shift ;;
  esac
done

[ -n "$DASH" ] || usage
[ -f "$DASH" ] || { echo "no such file: $DASH" >&2; exit 2; }
DASH=$(realpath "$DASH")

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$DASH" || {
  echo "not valid JSON: $DASH" >&2
  exit 2
}

# Resolved from the flake rather than found by globbing /nix/store, where stale
# outputs from earlier failed builds sort ahead of the current one.
echo "resolving grafana from the flake..." >&2
GF=$(nix build .#nixosConfigurations.oreamnos.config.services.grafana.package \
       --no-link --print-out-paths 2>/dev/null | tail -1)
[ -n "$GF" ] || { echo "could not build grafana package" >&2; exit 1; }
echo "grafana: $GF" >&2

ROOT=$(mktemp -d -t grafana-dashboard-test-XXXXXX)
mkdir -p "$ROOT"/{data,logs,plugins,prov/dashboards,dash}
cp "$DASH" "$ROOT/dash/dashboard.json"

cat > "$ROOT/prov/dashboards/test.yaml" <<EOF
apiVersion: 1
providers:
  - name: 'test'
    type: file
    allowUiUpdates: false
    options:
      path: $ROOT/dash
EOF

cat > "$ROOT/grafana.ini" <<EOF
[paths]
data = $ROOT/data
logs = $ROOT/logs
plugins = $ROOT/plugins
provisioning = $ROOT/prov
[server]
http_port = $PORT
[analytics]
reporting_enabled = false
check_for_updates = false
EOF

PIDFILE="$ROOT/grafana.pid"

# Invoked by the trap below, which shellcheck cannot see.
# shellcheck disable=SC2329
cleanup() {
  if [ "$KEEP" -eq 0 ] && [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -rf "$ROOT"
  fi
}
trap cleanup EXIT

( cd "$ROOT" && setsid nohup "$GF/bin/grafana" server \
    --homepath "$GF/share/grafana" --config "$ROOT/grafana.ini" \
    > "$ROOT/run.log" 2>&1 < /dev/null & echo $! > "$PIDFILE" )

# First start runs migrations and unpacks bundled plugins; a minute is normal.
echo -n "waiting for grafana" >&2
for _ in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/health" || true)" = "200" ]; then
    healthy=1
    break
  fi
  echo -n "." >&2
  sleep 2
done
echo >&2

if [ "${healthy:-0}" != "1" ]; then
  echo "grafana did not become healthy; last log lines:" >&2
  tail -20 "$ROOT/run.log" >&2
  exit 1
fi

UID_=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
# v2 keeps the uid under metadata; v1 has it at the top level.
print(d.get('metadata', {}).get('name') or d.get('uid', ''))
" "$DASH")

if [ -z "$UID_" ]; then
  UID_=$(curl -s -u admin:admin "http://127.0.0.1:$PORT/api/search?type=dash-db" |
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['uid'] if d else '')")
fi

[ -n "$UID_" ] || { echo "dashboard did not provision at all" >&2; tail -20 "$ROOT/run.log" >&2; exit 1; }

curl -s -u admin:admin "http://127.0.0.1:$PORT/api/dashboards/uid/$UID_" > "$ROOT/fetched.json"

# set -e would abort here on a failing report, skipping the --keep message
# below — which is exactly when you most want the instance left up to poke at.
set +e
python3 - "$ROOT/fetched.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1]))
db = doc.get("dashboard") or {}
panels = db.get("panels") or []

if not panels:
    print("FAIL: dashboard came back with no panels")
    sys.exit(1)

print(f"\ndashboard: {db.get('title')!r}  ({len(panels)} panels)\n")
print(f"{'id':>5}  {'type':<12} {'tgts':>4} {'ovr':>4}  {'transformations':<28} title")
print("-" * 100)

broken = []
for p in sorted(panels, key=lambda x: x.get("id", 0)):
    tf = p.get("transformations") or []
    ids = [t.get("id", "") for t in tf]
    if any(i == "" for i in ids):
        broken.append((p.get("id"), p.get("title")))
    shown = ",".join(i or "<EMPTY>" for i in ids) if ids else "-"
    print(
        f"{p.get('id', '?'):>5}  {p.get('type', '?'):<12} "
        f"{len(p.get('targets') or []):>4} "
        f"{len(((p.get('fieldConfig') or {}).get('overrides')) or []):>4}  "
        f"{shown:<28} {p.get('title', '')}"
    )

if broken:
    print("\nFAIL: transformations converted to an empty id on:")
    for pid, title in broken:
        print(f"  panel {pid}: {title}")
    print(
        "\nA transformation must be written as\n"
        '  {"kind": "Transformation", "group": "<id>", "spec": {"options": {...}}}\n'
        "The classic v1 form {\"id\": ..., \"options\": ...} is accepted and silently dropped."
    )
    sys.exit(1)

print("\nOK: every panel converted cleanly")
PY
status=$?

if [ "$KEEP" -eq 1 ]; then
  echo
  echo "grafana left running: http://127.0.0.1:$PORT  (admin:admin)"
  echo "  state:  $ROOT"
  echo "  log:    $ROOT/run.log"
  echo "  stop:   kill $(cat "$PIDFILE"); rm -rf $ROOT"
fi

exit $status
