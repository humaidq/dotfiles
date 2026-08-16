---
name: deploying-a-host
description: Use when deploying, rebuilding, or switching a NixOS host in this flake — especially a remote one over the nebula mesh (bingo, bongo, oreamnos) from a local checkout, or when a build must be validated before switching.
---

# Deploying a host

## Overview

Three ways to apply a config, in order of how often they fit:

| Situation | Command |
|---|---|
| The host you are sitting on | `sudo nixos-rebuild switch --flake .#<host>` |
| A remote host, from this checkout | build here, push the closure over ssh (below) |
| A remote host, from GitHub | `sudo nixos-rebuild switch --flake github:humaidq/dotfiles#<host> --refresh` (needs a push first) |

The remote-from-checkout path is the one worth knowing: it deploys **uncommitted
or just-committed** local work without a GitHub round-trip, which is what you want
while iterating.

## Remote deploy over the mesh

Hosts are reachable only over the nebula mesh. Mesh addresses:

| Host | Mesh IP | Arch |
|---|---|---|
| oreamnos | 10.10.0.12 | x86_64-linux |
| bongo | 10.10.0.16 | x86_64-linux |
| bingo | 10.10.0.18 | x86_64-linux |

**Connect by IP, never by name.** `ssh bingo` silently lands on **bongo** — the
session looks normal and you only notice because the LAN is wrong. Always use the
mesh IP and sanity-check `hostname` first.

### 1. Reuse one ssh socket

Every fresh ssh to a mesh host costs a hardware-key touch. Open one
ControlMaster on a short path and point `nixos-rebuild` at it, or every
closure-copy and the activation each cost a touch:

```bash
S=/tmp/claude-1000/cmb   # short path: the scratchpad path is too long for a unix socket
ssh -o ControlMaster=yes -o ControlPath=$S -o ControlPersist=45m -fN humaid@10.10.0.18
ssh -o ControlPath=$S humaid@10.10.0.18 hostname   # confirm it is the host you meant
```

### 2. Validate the build before switching (optional but cheap)

A `switch` builds anyway, but building the toplevel first catches eval/compile
errors without touching the running host:

```bash
nix build .#nixosConfigurations.<host>.config.system.build.toplevel --no-link
```

Same-arch hosts build locally; `nixos-rebuild` also uses any configured
distributed builders (anoa builds on oreamnos). A host of a different arch than
this laptop needs `--build-host` or a remote builder — don't assume a local
build will work.

### 3. Switch

```bash
export NIX_SSHOPTS="-o ControlPath=/tmp/claude-1000/cmb -o ControlMaster=no"
nixos-rebuild switch --flake .#<host> \
  --target-host humaid@10.10.0.18 \
  --use-remote-sudo
```

`NIX_SSHOPTS` is what makes the copy reuse the warm socket. `--use-remote-sudo`
runs activation via sudo on the target; the routers have passwordless sudo, so
it does not prompt. If a host ever does prompt, the deploy hangs — hand the
command to the user to run with `! ` instead.

## Secrets

Deploys carry the committed/working-tree `secrets/*.yaml` as-is; sops-nix
decrypts them at activation with the target's own age key. Watch the activation
output — it prints `adding secret:` / `modifying secret:` / `removing secret:`
for each change, which is the confirmation that a secret edit landed.

## Verify

Never call a deploy done off the `Done.` line alone. Check the thing you changed:

```bash
ssh -o ControlPath=$S humaid@10.10.0.18 'systemctl status <unit> --no-pager | head'
ssh -o ControlPath=$S humaid@10.10.0.18 'journalctl -u <unit> --no-pager -n 20'
```

`nix flake check` is the repository's real gate (CI only runs `nix flake show`);
run it before pushing, but it builds every host and is slow, so a single-host
build (step 2) is the faster loop while iterating.
