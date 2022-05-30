# This file contains virtualisation settings.
{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.hsys;
in
{
  options.hsys.virtualisation = mkOption {
    description = "Enables virtualisation services";
    type = types.bool;
    default = false;
  };

  config = mkIf cfg.virtualisation {
    virtualisation.docker = {
      enable = false;
      autoPrune.enable = true; # autoPrune.dates default "weekly"
    };
    virtualisation.virtualbox.host = {
      enable = true;
      enableExtensionPack = true;
    };
    environment.systemPackages = with pkgs; [
      qemu_full
      gnome.gnome-boxes
    ];
  };
}
