ITER=3
MODE="interactive" # interactive | login
ZSH_BIN="${ZSH_BIN:-zsh}"
QUIET=0
LC_ALL=C

usage() {
  cat <<EOF
Usage: $0 [-n ITER] [--login|--interactive] [-q]
  -n ITER        Number of runs (default: 3)
  --login        Benchmark login shell startup (reads zprofile/zlogin)
  --interactive  Benchmark interactive startup (reads zshrc) [default]
  -q             Quiet (suppress per-run output)
  ZSH_BIN=/path/to/zsh to choose zsh binary (env var)
EOF
}

# Parse args
while (("$#")); do
  case "$1" in
  -n)
    ITER="${2:-}"
    shift 2
    ;;
  --login)
    MODE="login"
    shift
    ;;
  --interactive)
    MODE="interactive"
    shift
    ;;
  -q)
    QUIET=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown arg: $1" >&2
    usage
    exit 1
    ;;
  esac
done

# Validate
if ! command -v "$ZSH_BIN" >/dev/null 2>&1; then
  echo "Error: zsh not found at '$ZSH_BIN'." >&2
  exit 1
fi
if ! [[ "$ITER" =~ ^[0-9]+$ ]] || ((ITER < 1)); then
  echo "Error: -n ITER must be a positive integer." >&2
  exit 1
fi

# Build the zsh command array
case "$MODE" in
interactive) ZSH_CMD=("$ZSH_BIN" -i -c exit) ;;
login) ZSH_CMD=("$ZSH_BIN" -l -c exit) ;;
*)
  echo "Internal error: unknown mode '$MODE'"
  exit 1
  ;;
esac

# Choose timing command array: prefer /usr/bin/time (Linux), fall back to builtin time
TIME_CMD=()
if command -v /usr/bin/time >/dev/null 2>&1; then
  TIME_CMD=(/usr/bin/time -f %e)
elif command -v gtime >/dev/null 2>&1; then
  # macOS with gnu-time from brew
  TIME_CMD=(gtime -f %e)
fi

run_once() {
  # Print elapsed seconds as float
  if ((${#TIME_CMD[@]})); then
    # External time prints to stderr; capture only that
    "${TIME_CMD[@]}" -- "${ZSH_CMD[@]}" >/dev/null 2>&1 | cat
  else
    # Fallback to bash builtin time
    local out
    TIMEFORMAT='%R'
    # `time` writes to stderr; capture it and print just the real seconds
    out=$({ time "${ZSH_CMD[@]}" >/dev/null; } 2>&1)
    printf "%s" "$out"
  fi
}

((QUIET == 1)) || echo "Benchmarking: ${ZSH_CMD[*]}  (runs: $ITER)"

times_file="$(mktemp)"
cleanup() { rm -f "$times_file"; }
trap cleanup EXIT

for ((i = 1; i <= ITER; i++)); do
  t="$(run_once)"
  printf "%s\n" "$t" >>"$times_file"
  ((QUIET == 1)) || printf "  run %2d: %s s\n" "$i" "$t"
done

# Stats via awk
awk '
  NF > 0 {
    x = $1 + 0
    if (NR == 1) { min = x; max = x }
    if (x < min) min = x
    if (x > max) max = x
    sum += x
    sumsq += x * x
  }
  END {
    n = NR
    if (n == 0) {
      printf("\nresults\n  runs:   0\n  avg:    0.0000 s\n  min:    -\n  max:    -\n  stddev: 0.0000 s\n")
      exit
    }
    avg = sum / n
    var = (n > 1 ? (sumsq - sum * sum / n) / (n - 1) : 0)
    sd  = (var > 0 ? sqrt(var) : 0)
    printf("\nresults\n")
    printf("  runs:   %d\n", n)
    printf("  avg:    %.4f s\n", avg)
    printf("  min:    %.4f s\n", min)
    printf("  max:    %.4f s\n", max)
    printf("  stddev: %.4f s\n", sd)
  }
' "$times_file"
