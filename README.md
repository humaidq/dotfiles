# sifrOS: My Secure NixOS Configuration

## Goal

sifrOS is an opinionated but modular framework for NixOS for my use case.

Features:

- Secure by default
    - The system is configured to be secured by default, enabling firewall and hardening system and kernel settings.
    - We aim with security through simplicity by using a minimal set of software per module.
    - Firefox is configured to use uBlock Origin by default, and enable anti-fingerprinting settings and more.
- Properly configured window manager/desktop environments
    - i3wm is installed and configured to work out of the box, with media controls, locking, compositor and more.
- Modular
    - Components are separated by modules, and the configuration is available as Flakes.
- Clean
    - The system follows a common theme and branding.
    - A minimal boot screen, login menu, and desktop.
    - `$HOME` is mostly de-cluttered, and XDG user directories (e.g. Desktop, Downloads) are simplified.

## General Information

Based on [NixOS Wiki Comparison definitions](https://nixos.wiki/wiki/Comparison_of_NixOS_setups).

| Flakes | Home Manager | Secrets | File System | System Encryption | Opt-in state | Display Server | Desktop Environment |
| - | - | - | - | - | - | - | - |
| Yes | Yes | None (Yet) | Btrfs | Yes (LUKS) | No | X, Wayland | i3, Gnome |

## Building

To build Raspberry Pi 4 image:
```
nix build .#rpi4
```

To build x86-64 installer image:
```
nix build .#x86-installer
```

## Installation

Create an installer for the required architecture, and boot. After boot, you should automatically be logged in. A window should appear with the installer, the prompt will guide you through the installation process.

## NixOS Example Usage

To rebuild, run the following in the repository directory:
```
doas nixos-rebuild switch --flake .#goral
```

## macOS Example Setup & Usage

These commands should be run after [installing Nix](https://nixos.org/download), and cloning this repository. The commands should be run while in this repository.

First time run:
```
nix --extra-experimental-features 'flakes nix-command' run nix-darwin -- switch --flake .#takin
```
Then (without sudo):
```
darwin-rebuild switch --flake .#takin
```

## TODOs

- Automated install script/image
- Raspberry Pi image
- Docker image
- Secret management
- Deploy Tool (deploy-rs)
