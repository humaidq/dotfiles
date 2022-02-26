# This contains settings to provide a graphical system.
{ config, pkgs, lib, ... }:
with lib;
let
    cfg = config.hsys;
    needDisplayServer = cfg.enableGnome|| cfg.enablei3;
in
{
  options.hsys.enableGnome =mkOption {
    description = "Enable Gnome desktop environment";
    type = types.bool;
    default = false;
  };
  options.hsys.enablei3 = mkOption {
    description = "Enable the i3 window manager";
    type = types.bool;
    default = false;
  };

  config = mkMerge [
    (mkIf needDisplayServer { # Global Xorg/wayland and desktop settings go here
      services = {
        # Configure keymap in X11 (outdated - we use wayland now)
        xserver = {
          enable = true;
          layout = "us,ar";
          xkbOptions = "caps:escape";
	  enableCtrlAltBackspace = false; # security?
	  
        };
        printing = {
          enable = true;
	  drivers = [
	    pkgs.epson-escpr
	  ];
	};
        pipewire = {
          enable = true;
          alsa.enable = true;
          alsa.support32Bit = true;
          pulse.enable = true;
	  media-session.enable = true;
        };
      };
      programs.xwayland.enable = true;
      environment.systemPackages = with pkgs; [

      ];
      fonts = {
        enableDefaultFonts = true;
	enableGhostscriptFonts = true;
	fonts = with pkgs; [
	  google-fonts
	  corefonts
	  roboto
	  ubuntu_font_family
	];
      };
    })

    (mkIf cfg.enableGnome { # These are set when gnome is enabled.
      services.xserver.desktopManager.gnome.enable = true;
      services.xserver.displayManager.gdm.enable = true;

      environment.gnome.excludePackages = [
        pkgs.gnome.geary
        pkgs.gnome.gnome-music
        pkgs.epiphany
      ];
      environment.systemPackages = with pkgs; [
        gnome.dconf-editor
      ];

    })

  ];
 
}

