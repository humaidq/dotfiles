# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Personal NixOS flake ("sifrOS") managing every machine the user owns: workstations, laptops, VPSes, routers, and SBCs. Each host is a NixOS configuration assembled from a shared module set. Always flakes — never `nix-channel`.

## Common commands

- Evaluate the flake and build every host (run before pushing): `nix flake check`
- Format the whole tree (nixfmt + deadnix + statix + shellcheck via treefmt): `nix fmt`
- Rebuild the current host from local checkout: `sudo nixos-rebuild switch --flake .#<hostname>`
- Rebuild from GitHub: `sudo nixos-rebuild switch --flake github:humaidq/dotfiles#<hostname> --refresh`
- Build an artifact (installer ISO, RPi SD image, serow VM): `nix build .#<installer|rpi4-bootstrap|rpi5-bootstrap|serow-vm>`
- Edit a sops-encrypted secret: `sops secrets/<file>.yaml` (keys and access rules live in `.sops.yaml`)
- Build just one host without switching: `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`

CI runs `nix flake show` only — `nix flake check` is the real gate and must pass locally.

## Architecture

### Flake wiring

`flake.nix` uses `flake-parts` and imports `./hosts`, which is where the actual flake outputs are defined. `hosts/default.nix` is the central host registry:

- Each host directory (`hosts/<name>/`) exports a NixOS module via `nixosModules.host-<name>`.
- `nixosConfigurations.<name>` is then built by `lib.nixosSystem` with `specialArgs = { self, inputs, vars }` plus a derived `vars.homeServerDomains` (the list of nginx vhosts on `oreamnos`, so other hosts can reference them).
- Generator hosts (`x86-installer`, `rpi4-bootstrap`, `rpi5-bootstrap`) are also defined here and re-exported under `packages.<system>`.
- `hydraJobs` mirrors the buildable hosts.

When adding a new host: create `hosts/<name>/default.nix`, register it under both `nixosModules` and `nixosConfigurations` in `hosts/default.nix`, add its age key to `.sops.yaml` if it needs secrets, and add it to `hydraJobs` if it should build in CI.

### Module layout and the `sifrOS` namespace

`flake.nix` re-exports the module tree under `nixosModules.sifrOS.*` (e.g. `sifrOS.base`, `sifrOS.desktop`, `sifrOS.personal.work`). Host modules import from this namespace via `self.nixosModules.sifrOS.<thing>` rather than relative paths. The trees:

- `modules/base/` — always imported. Defines the `sifr.*` option namespace (`modules/base/options/sifr.nix`), sets up the primary user, home-manager, nix settings, overlays, and pulls in `applications/`, `development/`, `system/`, `user/`, plus `../home-server`.
- `modules/desktop/` — Sway/labwc, apps, bar, screenshot, clipboard.
- `modules/server/`, `modules/laptop/`, `modules/router/`, `modules/security/`, `modules/persist/` — role layers; `persist` has both `btrfs.nix` and `zfs.nix` variants.
- `modules/home-server/` — the services hosted on `oreamnos` (immich, media, AI, DAV, web, etc.). Imported by `modules/base/default.nix` but gated by options so non-server hosts pay no cost.
- `modules/personal/` — feature modules toggled per-host (`work`, `university`, `amateur`, `dns`, `o11y`, `focus-mode`, `kids`, `research`, `security-research`, `networking`, `receipt`, `ssh`). Most expose a `sifr.personal.<feature>.enable` flag.
- `modules/installer/` — used by the x86 installer ISO.

Hosts configure themselves by setting `sifr.*` options (see `hosts/anoa/default.nix` for a representative example), not by adding random NixOS config inline.

### specialArgs available everywhere

Modules can take `{ self, inputs, vars, ... }`. `vars.user` is the primary username (currently `humaid`). `vars.homeServerDomains` is the list of nginx vhosts on the home server, computed in `hosts/default.nix` so other hosts can punch through DNS/routing for them.

### Overlays

`modules/base/default.nix` injects overlays for `unstable` (nixos-unstable pkgs), `liquidctl`, `ls-colors`, `ufetch`, `zsh-extract`, and a pinned `nwjs`. Custom packages live under `overlays/<name>/`. There is no separate overlays registration — add to the overlay list in `modules/base/default.nix`.

### Secrets

`sops-nix` with age. `.sops.yaml` defines which host keys can decrypt which files in `secrets/`. Common patterns:

- Host-specific secrets: `secrets/<host>.yaml`, readable by that host plus admin hosts (`oreamnos`, `anoa`, `serow`).
- Shared secrets: `secrets/all.yaml` and `secrets/home-server.yaml`.
- When adding a new host that needs secrets, add its age public key to `.sops.yaml` and `sops updatekeys` each affected file.

### Binary cache

`cache.huma.id` is configured as an extra substituter in `flake.nix`'s `nixConfig`. `anoa` uses `oreamnos` as a distributed build machine over SSH (key path comes from sops).

## Conventions

- Option flags live under `sifr.*` (per-feature, e.g. `sifr.desktop.sway.enable`, `sifr.personal.work.enable`). Add new options to `modules/base/options/` or a feature-local `options` block rather than scattering them.
- Keep commit messages concise and descriptive (per `AGENTS.md`).
- Always commit with `--no-gpg-sign` (the user's signing key is a hardware key that can't be touched from an agent session).
- The default branch is `master`.
