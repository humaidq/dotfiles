# sifrOS: My Secure NixOS Configuration

![NixOS Flake](https://img.shields.io/badge/NixOS-flake-blue?logo=nixos)
![Wayland By Default](https://img.shields.io/badge/Wayland-196f5e?logo=wayland)
![secrets sops-nix](https://img.shields.io/badge/secrets-sops--nix-blue)

## Goal

sifrOS should be a secure, minimal, and modular NixOS framework tailored to my
use case.

### Features

- Minimal Sway desktop.
- Emacs configured with Doom Emacs ([configuration](https://github.com/humaidq/doomd)).
- Shell configured with modern tools & improvements, such as nix-direnv,
  zoxide, eza, zsh with built-in autosuggestions, useful aliases,
  and more.
- Neovim (NixVim) configured with LSP, telescope, and other QoL plugins.
- Secrets management with `sops-nix`.
- Browser configured with extensions.
- Nebula mesh VPN setup for machines.
  - Alternatively, Tailscale with auto-authentication (using sops-nix).
- Home server setup.
  - WebDAV, CalDAV, CardDav for syncing between devices.
  - Immich for photo sync.
  - Logging and monitoring using Grafana.
  - Ad-blocking DNS server using blocky.
  - Nix binary cache and NTP server.
  - Media server.
- Web server for my personal website and other services.
- "Server Mode" specialisation for laptops.
- System hardening for kernel, web server, etc.

## Hosts

Systems managed by this flake.

| Name         | System                   | CPU          | RAM   | GPU               | Role   | OS    | State |
|--------------|--------------------------|--------------|-------|-------------------|--------|-------|-------|
| `oreamnos`   | Home Workstation         | AMD 5995WX   | 128GB | NVIDIA RTX 4070   | Server | NixOS | OK    |
| `anoa`       | ThinkPad X1 Carbon Gen13 | Ultra 7 268V | 32GB  | Intel Arc 140V    | Laptop | NixOS | OK    |
| `serow`      | ThinkPad T590            | i7-8565U     | 16GB  | Intel UHD 8th Gen | Laptop | NixOS | OK    |
| `duisk`      | Vultr VPS                | vCPU         | 2GB   | None              | Server | NixOS | OK    |
| `lighthouse` | Vultr VPS                | vCPU         | 1GB   | None              | Server | NixOS | OK    |
| `boerbok`    | Star64                   | SiFive       | 8GB   | None              | Server | NixOS | WIP   |
| `argali`     | RPi 4B                   | BCM2711      | 8GB   | None              | Server | NixOS | WIP   |
| `arkelli`    | RPi 4B                   | BCM2711      | 8GB   | None              | Server | NixOS | WIP   |

<!--
Possible names:
- addax
- kobus
- chiru
- tur
- urial
- sable
- eland
- markhor
- bongo
- rhebok
- gaur
- topi
- puku

- saola
- tahr
- goral
- takin
-->

Rebuilding a system:

```
sudo nixos-rebuild switch --flake github:humaidq/dotfiles#<hostname> --refresh
```

## Bootstrapping

### x86 Machine

Build and flash the installer image:

```
nix build github:humaidq/dotfiles#installer
sudo cp ./result/iso/*.iso /dev/sdX
```

Alternatively, this ISO works with [Ventoy].

After booting, either partition manually or use the disko configuration. Copy
the hardware configuration and configure the host on another machine, push it
to the repository.

Then you may finally install with:

```
sudo nixos-install --root /mnt --flake github:humaidq/dotfiles#<host>
```

### Raspberry Pi

Build and flash the SD card image:

```
nix build github:humaidq/dotfiles#packages.aarch64-linux.rpi4-bootstrap
sudo cp ./result/*.img /dev/mmcblkX
```

When booted, the image should auto-resize to fill the card. You should be able
to SSH into the device using SSH key.

Once a new host is configured for this machine, simply rebuild the system
directly from the GitHub repository.

Don't forget to add the age public key into `.sops.yaml` and update the keys.

## macOS Setup & Usage

Install Nix using the [Determinate Systems installer](https://zero-to-nix.com/start/install).

```
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

Then run the following (without sudo):

```
darwin-rebuild switch --flake github:humaidq/dotfiles#takin --refresh
```

[Ventoy]: https://www.ventoy.net/en/index.html
