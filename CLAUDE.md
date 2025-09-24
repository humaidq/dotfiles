# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is **sifrOS**, a secure, minimal, and modular NixOS/nix-darwin configuration framework. The repository contains declarative system configurations for multiple hosts including workstations, laptops, servers, and macOS systems.

## Architecture

### Core Structure
- **`flake.nix`**: Main flake definition with inputs and outputs
- **`modules/`**: Reusable NixOS modules organized by functionality
- **`hosts/`**: Host-specific configurations for each machine
- **`overlays/`**: Package overlays and custom packages
- **`secrets/`**: Encrypted secrets managed with sops-nix

### Module Organization
The `modules/` directory contains:
- **`applications/`**: Application configurations (Emacs, Firefox, etc.)
- **`profiles/`**: System profiles (base, laptop, server, work, research)
- **`graphics/`**: Desktop environment and graphics configurations
- **`networking/`**: Network setup including Nebula mesh VPN and Tailscale
- **`home-server/`**: Services like Immich, WebDAV, DNS blocking
- **`security/`**: System hardening configurations
- **`shell/`**: Shell environment with modern tools and aliases

### Host Types
- **NixOS Systems**: Workstations, laptops, and servers
- **macOS Systems**: nix-darwin configurations (e.g., `takin`)
- **Bootstrap Images**: RPi and x86 installer images

## Common Commands

### Building and Switching Systems

**NixOS systems** (run on the target machine):
```bash
# Remote rebuild from GitHub
sudo nixos-rebuild switch --flake github:humaidq/dotfiles#<hostname> --refresh

# Local rebuild (when working in the repo)
sudo nixos-rebuild switch --flake .#<hostname> --refresh

# With better output formatting
sudo nixos-rebuild switch --flake .#<hostname> --refresh --log-format internal-json -v --show-trace &| nom --json
```

**macOS systems** (nix-darwin):
```bash
darwin-rebuild switch --flake github:humaidq/dotfiles#takin --refresh
```

### Building Images

**x86 installer ISO**:
```bash
nix build github:humaidq/dotfiles#installer
```

**Raspberry Pi SD card image**:
```bash
nix build github:humaidq/dotfiles#packages.aarch64-linux.rpi4-bootstrap
```

### Development Commands

**Format code**:
```bash
nix fmt
```

**Check flake**:
```bash
nix flake check
```

**Development shell**:
```bash
nix develop
```

### Useful Shell Aliases
The configuration includes several helpful aliases in `modules/shell/default.nix`:
- `nrb`: Remote rebuild with monitoring
- `nrbl`: Local rebuild with monitoring  
- `nrblo`: Local rebuild offline with monitoring

## Key Features

### Secrets Management
- Uses **sops-nix** for encrypted secrets
- Secrets stored in `secrets/` directory (YAML format)
- Age keys automatically generated per host

### Networking
- **Nebula mesh VPN** for secure inter-host communication
- **Tailscale** as alternative VPN solution
- Custom DNS with ad-blocking via blocky

### Home Server Stack
- **Immich**: Photo management and sync
- **WebDAV/CalDAV/CardDAV**: File and calendar sync
- **Paperless-NGX**: Document management
- **Grafana**: Monitoring and logging
- **Nix binary cache**: For faster builds

### Security
- System hardening configurations
- Proper firewall and service isolation
- Security-focused default configurations

## Working with This Codebase

### Adding a New Host
1. Create directory in `hosts/<hostname>/`
2. Add `default.nix` and `hardware.nix` 
3. Update `hosts/default.nix` to include the new host
4. Add age public key to `.sops.yaml` if secrets are needed

### Adding a New Module
1. Create module file in appropriate `modules/` subdirectory
2. Add to `modules/modules-list.nix` import list
3. Define options in the module or `modules/options.nix`

### Secrets Management
- Edit secrets: `sops secrets/all.yaml`
- Update keys after adding new hosts: regenerate with sops
- Secrets are automatically decrypted during system activation

### Testing Changes
- Use `nix flake check` to validate syntax
- Test builds with `nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel`
- For major changes, test in VM first

## Development Notes

- All systems use flakes exclusively
- Unstable packages available via `pkgs.unstable.*`
- Home Manager integrated for user-level configurations
- Uses nixfmt-rfc-style for code formatting
- Treefmt configured for automated formatting