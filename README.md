# sifrOS: My Secure NixOS Configuration
![NixOS Flake](https://img.shields.io/badge/NixOS-flake-blue?logo=nixos)
![Wayland By Default](https://img.shields.io/badge/Wayland-196f5e?logo=wayland)
![secrets sops-nix](https://img.shields.io/badge/secrets-sops--nix-blue)


## Goal

sifrOS is an opinionated but modular framework for NixOS, tailored to my use
case. The goal is to create a reusable configuration for all my computer
systems. This repository is modular, you should be able to set your username by
setting a single option.

### Features

- Secure by default
    - The system is configured to be secured by default, enabling firewall and
      hardening system and kernel settings.
    - We aim with security through simplicity by using a minimal set of
      software per module.
    - Firefox is configured to use uBlock Origin by default, and enable
      anti-fingerprinting settings, DuckDuckGo by default.
- Properly configured desktop environment
    - Gnome only for now.
- Modular
    - Components are separated by modules, and the configuration is available
      as Flakes.
    - User information can be set as an option, username is not hardcoded.
- Clean
    - The system follows a common theme and branding.
    - A minimal boot screen, login menu, and desktop.
    - `$HOME` is mostly de-cluttered, and XDG user directories (e.g. Desktop, Downloads) are simplified.

## Hosts

Systems managed by this flake.

| Name | System | CPU | RAM | GPU | Role | OS | State |
| ---- | ----- | --- | --- | --- | ---- | -- | ----- |
| `serow` | ThinkPad T590 | i7-8565U | 16GB | Intel UHD 8th Gen | 💻️ | ❄️ | ✅ |
| `tahr` | ThinkPad P1 Gen3 | i9-10885H | 32GB | NVIDIA Quadro T2000 | 💻️ | ❄️ | ✅ |
| `takin` | MacBook Pro | M2 Max | 64GB | M2 Max | 💻️ |  | 🚧 |
| `goral` | VMWare Fusion | M2 Max | 64GB | M2 Max | 💻️ | ❄️ | ✅ |
| `duisk` | Vultr VPS | vCPU | 4GB | None | ☁️ | ❄️ | ✅ |
| `argali` | RPi 4B | BCM2711 | 8GB | None | ☁️ | ❄️ | ✅ |
| `boerbok` | Star64 | SiFive | 8GB | None | ☁️ | ❄️ | 🚧 |

## Desktop

There are two options:
- Gnome: For a fully featured, stacking, desktop environment.
- Sway: For a minimal, tiling, window manager & compositor.

## Building

To build Raspberry Pi 4 image:
```
nix build .#argali
```

## Installation

1. Use the regular [NixOS installer image from
   nixos.org](https://nixos.org/download/), install normally.
2. Clone this repository and `cd` into it.
3. Copy over `/etc/nixos/hardware-configuration.nix` to `hardware/<hostname>.nix`.
4. Copy over `/etc/nixos/configuration.nix` to `hosts/<hostname>.nix`.
5. Make sure these two filenames match.
6. Edit `flake.nix` and add your system definition (copy an existing as a
   template).
7. Edit `hosts/<hostname>.nix`, include `sifr` configurations. See other hosts
   for example.
    - Remove everything, including comments, stateVersion, and the import for
      hardware config.
    - Only keep the `boot.loader` configuration.
    - Look at other hosts, should be a minimal file.
8. For the first build, better to use `boot` option:
   `sudo nixos-rebuild boot --flake .#<hostname>`. Then reboot the system.

To rebuild, run the following in the repository directory:
```
doas nixos-rebuild switch --flake .#goral
```

## macOS Example Setup & Usage

These commands should be run after [installing
Nix](https://nixos.org/download), and cloning this repository. The commands
should be run while in this repository.

First time run:
```
nix --extra-experimental-features 'flakes nix-command' run nix-darwin -- switch --flake .#takin
```
Then (without sudo):
```
darwin-rebuild switch --flake .#takin
```

## TODOs

- [ ] Disko for disk configuration
- [ ] Raspberry Pi image
