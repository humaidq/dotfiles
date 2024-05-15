# sifrOS: My Secure NixOS Configuration

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
| Yes | Yes | sops-nix | Btrfs | Yes (LUKS) | No | Wayland and X | Gnome |

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
