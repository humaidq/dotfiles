---
name: editing-grafana-dashboards
description: Use when adding or editing panels in modules/router/dashboard.json, when a provisioned Grafana panel renders empty or loses its transformations, or when checking a dashboard change before deploying it to oreamnos
---

# Editing Grafana dashboards

## Overview

`modules/router/dashboard.json` is the one dashboard this flake owns. It is
provisioned onto oreamnos from `modules/personal/o11y/server.nix`, which means
the file is authoritative and the dashboard is read-only in the browser.

The file is written in the **v2 dashboard schema**
(`dashboard.grafana.app/v2`). Grafana 13.0.3 does not register v2 — it exposes
`v0alpha1`, `v1` and `v1beta1` — and converts the file on read. Almost
everything survives that conversion. The parts that do not fail *silently*,
which is the single most important thing to know before editing this file.

**Always round-trip a change through a real Grafana before deploying it.** The
build does not validate dashboard JSON; `nix flake check` will happily pass a
dashboard whose panels are all blank.

## Structure

Two halves that must be kept in step:

- `spec.elements` — a map of `panel-<N>` to a Panel object. `spec.id` inside
  must equal the `<N>` in the key.
- `spec.layout` — a `TabsLayout` of tabs, each holding a `GridLayout` whose
  items reference elements by name.

An element with no matching `GridLayoutItem` is parsed, stored, and never
rendered. Nothing warns about it.

Grid is 24 columns wide; `x`/`y`/`width`/`height` are in grid units.

## The kind/group/spec envelope

v2 wraps polymorphic things in an envelope, and each one puts the type
identifier in a different field. Getting this wrong is where the silent
failures come from:

| Thing | Envelope |
|---|---|
| Query | `{kind: "DataQuery", group: "prometheus", version: "v0", datasource: {...}, spec: {expr, ...}}` |
| Visualisation | `{kind: "VizConfig", group: "<viz type>", version: "13.0.3", spec: {options, fieldConfig}}` |
| Transformation | `{kind: "Transformation", group: "<transform id>", spec: {options: {...}}}` |

Note the asymmetry:

- For **VizConfig**, `group` is the panel type (`timeseries`, `table`,
  `piechart`) and the options sit directly in `spec`.
- For **Transformation**, `kind` is the literal string `"Transformation"`,
  `group` carries the transformation id (`merge`, `organize`), and the options
  are nested one level deeper in `spec.options`.

### The transformation trap

Writing a transformation in the classic v1 form — `{"id": "merge", "options":
{}}` — produces **no error at any layer**. The file loads, the dashboard
provisions, the panel appears, and the transformation comes back from the API
as:

```json
{"id": "", "options": null}
```

A table built on `merge` + `organize` then renders as several disconnected
frames with raw `Value #A` column names instead of one joined table. The only
way to catch it is to fetch the dashboard back and look. `{"kind": "<id>",
"spec": {...}}` fails the same way — both fields have to be right.

## Variables available

Set by the existing dashboard; reuse rather than adding new ones:

- `$network` — `bingo` or `bongo`, the router being viewed
- `${node:raw}` — Prometheus `instance`, derived from `$network`
- `${interface:raw}` — network device, derived from `${node:raw}`
- `${host:text}` — Loki `client_ip`
- `${ds_prometheus}` — the Prometheus datasource

Prometheus panels should filter on `instance="${node:raw}"` so they follow the
`$network` selector, matching every existing panel.

## Testing live on this system

`test-dashboard.sh` in this skill directory starts a throwaway Grafana with the
dashboard provisioned, fetches it back through the API, and prints what
actually survived:

```
.claude/skills/editing-grafana-dashboards/test-dashboard.sh modules/router/dashboard.json
```

It prints one line per panel — type, title, target count, transformation ids,
override count — and exits non-zero if any transformation converted to an empty
id. Grafana takes about a minute to become healthy on first start because it
runs migrations and downloads bundled plugins; the script waits for
`/api/health`.

To inspect something the script does not print, it leaves the instance running
with `--keep` and prints the URL and credentials (`admin:admin`).

### What "success" looks like

- every panel you added appears with the right `type`
- `targets` count matches the queries you wrote
- `transformations` shows real ids, not `""`
- `gridPos` is present, meaning the layout references resolved

### Expected noise

This line appears on every start and is **not** a failure:

```
[SHOULD NOT HAPPEN] failed to update managedFields ... field not declared in schema
```

It is Grafana's v2-to-internal converter complaining about a schema it does not
register. The dashboard and every panel still come back intact through the API.
Judge the run by what the API returns, not by this message.

## Gotchas that cost real time

**Do not use `ls -t /nix/store/*-thing` to find a build output.** Stale paths
from earlier failed builds sort first and you will test the wrong artifact.
Resolve from the built system instead:

```sh
sys=$(nix build .#nixosConfigurations.oreamnos.config.system.build.toplevel --no-link --print-out-paths)
grep -ohE '/nix/store/[a-z0-9]+-grafana[^ "]*' "$sys"/etc/systemd/system/grafana.service | head -1
```

**A leftover instance makes the test lie, not fail.** The script's health check
only asks whether *something* answers on the port, so a Grafana still running
from an earlier invocation gets fetched instead — and it reports on the
dashboard it was given, which is the previous version of the file. It reads as
a clean pass. `test-dashboard.sh` now refuses to start when the port already
answers, and no longer leaks its own instance (`$!` has to be grafana's pid;
both `setsid nohup grafana &` and `( cd … && grafana … & )` record a pid that
exits immediately, orphaning the server). If a run ever reports a panel count
that does not match the file, check for a stray instance first.

**Never `pkill -f grafana` or `pgrep -f bin/grafana`.** `-f` matches full
command lines, and the shell running your command contains that string, so you
kill your own session. Use a bracket to break the self-match:

```sh
pgrep -f "share/[g]rafana" | xargs -r kill
```

**A new file must be `git add`ed before Nix can see it.** Flakes only read
tracked files; an untracked `dashboard.json` fails evaluation with "not tracked
by Git" rather than anything about dashboards.

**Keep the file's formatting.** It is 2-space indented with literal UTF-8 (em
dashes are not escaped). Rewriting it from Python needs
`json.dump(..., indent=2, ensure_ascii=False)` and a trailing newline, or the
diff becomes the whole file.

## Deploying

`nix flake check` does not validate dashboards, so the round-trip test is the
gate. After it passes:

```
sudo nixos-rebuild switch --flake .#oreamnos
```

Grafana re-reads provisioned dashboards on restart. Because
`allowUiUpdates = false`, browser edits are blocked — change the JSON. To go
back to editing in the browser, flip that flag in
`modules/personal/o11y/server.nix` and re-export the file afterwards; Grafana
still overwrites UI changes on restart, so the file has to be kept in step
either way.
