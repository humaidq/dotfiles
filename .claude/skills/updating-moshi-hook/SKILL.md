---
name: updating-moshi-hook
description: Use when updating, bumping, or refreshing the moshi-hook package in this dotfiles repo to a newer (or latest) upstream version
---

# Updating moshi-hook

## Overview

`moshi-hook` is a prebuilt static Go binary (no public source) repackaged from
the getmoshi.app goreleaser tarballs. The package lives at
`overlays/moshi-hook/default.nix` and pins a `version` plus a per-arch `hash`
for `x86_64-linux` and `aarch64-linux`. Updating means bumping the version and
refreshing both hashes.

## Steps

1. **Find the target version.** For latest:
   ```bash
   curl -fsSL https://cdn.getmoshi.app/hook/latest/version.txt | tr -d '[:space:]'
   ```
   This returns e.g. `v0.2.51`. Drop the leading `v` for the nix `version` field.

2. **Prefetch both arch hashes** (the tarball URLs use `x86_64` and `arm64`):
   ```bash
   for arch in x86_64 arm64; do
     echo -n "$arch: "
     nix store prefetch-file --json \
       "https://cdn.getmoshi.app/hook/vVERSION/moshi-hook_Linux_${arch}.tar.gz" \
       | grep -o '"hash":"[^"]*"'
   done
   ```
   Replace `VERSION` with the number (no `v` — the URL keeps the `v`, so use the
   full `vVERSION`). `x86_64` → `x86_64-linux.hash`, `arm64` → `aarch64-linux.hash`.

3. **Edit `overlays/moshi-hook/default.nix`:** set `version` and replace both
   `hash` values under `sources`.

4. **Verify the build:**
   ```bash
   nix build --no-link .#nixosConfigurations.anoa.pkgs.moshi-hook
   ```

## Notes

- URL pattern: `https://cdn.getmoshi.app/hook/v${version}/moshi-hook_Linux_${arch}.tar.gz`.
- The tarball has no top-level directory (`sourceRoot = "."`), so packaging
  rarely changes across versions — only version + hashes need touching.
- `anoa` is the host that enables moshi (`sifr.personal.moshi.enable`), so it's
  the natural target for a build check.
