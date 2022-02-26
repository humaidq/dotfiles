# This contains settings to provide a graphical system.
{ config, pkgs, lib, ... }:
with lib;
let
    cfg = config.hsys;
in
{
  options.hsys.getDevTools =mkOption {
    description= "Installs development tools";
    type= types.bool;
    default= false;
  };
  #options.hsys.getTools =mkOption {
  #  description: "Installs development tools";
  #  type: types.bool;
  #  default: false;
  #};

  config = mkMerge [
    (mkIf cfg.getDevTools {
      environment.systemPackages = with pkgs; [
        # Programming
        go
        gcc
        gnupg
        gdb
        bvi
        plantuml
        bc
        gnumake
        bat
        ffmpeg
        lm_sensors
        minify
        mdbook
        hugo
      ];
    })
  ];

}
