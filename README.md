# sifrOS: My Secure NixOS Configuration

## Goal

sifrOS is an opinionated but modular framework for NixOS for my use case. The goal is to build a framework for me, so your use case and requirements might be different.

### Features

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

### Hosts

| Name | Arch/Kernel | Hardware | Description |
| ---- | ----------- | -------- | ----------- |
| serow | `x86_64-linux` | ThinkPad T590 | Development Laptop |
| tahr | `x86_64-linux` | ThinkPad P1 Gen3 | Work Laptop |
| takin | `aarch64-darwin` | MacBook Pro M2 Max | Main Laptop |
| goral | `aarch64-linux` | VMWare under macOS | Development VM |
| duisk | `x86_64-linux` | Vultr Cloud | Web Server for huma.id |
| argali | `aarch64-linux` | Raspberry Pi 4 | Tinkering Device (generator) |

Installer will prompt the user to reuse a previous host configuration or create a new one.

## General Information

An overview, based on [NixOS Wiki Comparison definitions](https://nixos.wiki/wiki/Comparison_of_NixOS_setups).

| Flakes | Home Manager | Secrets | File System | System Encryption | Opt-in state | Display Server | Desktop Environment |
| - | - | - | - | - | - | - | - |
| Yes | Yes | None (Yet) | Btrfs | Yes (LUKS) | No | X, Wayland | Gnome |

## Building

To build Raspberry Pi 4 image:
```
nix build .#argali
```

## Installation

Create an installer for the required architecture, and boot. After boot, you
should automatically be logged in. A window should appear with the installer,
the prompt will guide you through the installation process.

## NixOS Example Usage

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

- [ ] Raspberry Pi image
- [ ] Secrets management
