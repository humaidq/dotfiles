#!/bin/sh
nix-build '<nixpkgs/nixos>' -I \
	nixos-config=configuration.nix
