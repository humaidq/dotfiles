# Agent Guidance

This repository contains my personal NixOS flake along with modules and host definitions.

## Contributing
- Never use nix channel it is always nix flakes here
- Ensure the flake evaluates and hosts build by running `nix flake check` before pushing. This takes about an hour, so it is a human pre-push step — agents must not run it. Agents should build only the affected hosts instead: `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`.
- Format all files using the repository's formatter with `nix fmt`.
- Keep commit messages concise and descriptive.

