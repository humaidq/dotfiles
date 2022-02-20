# This is the commons files, which is attributes that spans different
# system types (e.g. graphical, server, RPi, etc).
{ config, pkgs, lib, ... }:
{
  imports = [ <home-manager/nixos> ];
  time.timeZone = "Asia/Dubai";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.humaid = {
    isNormalUser = true;
    extraGroups = [ "plugdev" "dialout" ]; # wheel removed since we use doas
    description = "Humaid AlQassimi";
    shell = pkgs.zsh;
  };

  services.power-profiles-daemon.enable = false;
  services.tlp = {
    enable = true;
    settings = {
      START_CHARGE_THRESH_BAT0 = 80;
      STOP_CHARGE_THRESH_BAT0 = 85;
    };
  };

  home-manager.users.humaid = {pkgs, lib, ...}: 
  let
    mkTuple = lib.hm.gvariant.mkTuple;
  in
  {
    xdg = {
      enable = true;
      mimeApps.enable = true;
      userDirs = {
        enable = true;
	createDirectories = false;
	desktop = "$HOME";
	documents = "$HOME/docs";
	download = "$HOME/inbox/web";
	music = "$HOME/docs/music";
	pictures = "$HOME/docs/pics";
	videos = "$HOME/docs/vids";
	publicShare = "";
	templates = "";
      };
    };
    programs.tmux = {
      enable = true;
      escapeTime = 0;
      keyMode = "vi";
    };
    programs.zsh = {
      enable = true;
      dotDir = ".config/zsh";
      autocd = true;
      enableVteIntegration = true;
      initExtra = ''
        # Load colours and set prompt
        autoload -U colors && colors
        PS1="%B%{$fg[red]%}[%{$fg[yellow]%}%n%{$fg[green]%}@%{$fg[blue]%}%M %{$fg[magenta]%}%~%{$fg[red]%}]%{$reset_color%}$%b "

        source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh
      '';
      shellAliases = {
        rebuild = "doas nixos-rebuild switch";
      };
      history = {
        size = 10000000;
	#path = "${config.xdg.dataHome}/zsh/history";
      };
      sessionVariables = {
        EDITOR = "nvim";
	LESSHISTFILE = "-";
      };
    };
    dconf.settings = {
      "org/gnome/desktop/interface" = {
        gtk-theme = "Adwaita-dark";
	clock-format = "12h";
	show-battery-percentage = true;
      };
      "org/gnome/desktop/sound" = {
        allow-volume-above-100-percent = true;
      };
      "org/gnome/desktop/wm/preferences" = {
        button-layout = "appmenu:minimize,close";
      };
      "org/gnome/desktop/input-sources" = {
        sources = [(mkTuple ["xkb" "us"] ) ( mkTuple ["xkb" "ara"] ) ( mkTuple["xkb" "fi"])];
	xkb-options = [ "caps:escape" ];
      };
    };
    gtk.gtk3.extraConfig = {
      gtk-application-prefer-dark-theme = true;
      gtk-cursor-theme-name = "Adwaita";
    };
    programs.go = {
      enable = true;
      goPath = "repos/go";
    };
    programs.ssh = {
      enable = true;
      matchBlocks."huma.id".user = "root";
    };
    programs.gpg = {
      enable = true;
      #homedir = "${config.home.homeDirectory}/.config/gnupg";
    };
    programs.git = {
      enable = true;
      package = pkgs.gitAndTools.gitFull;
      aliases = { co = "checkout"; };
      #signing.key = "";
      #signing.signByDefault = true;
      delta.enable = true;
      userName = "Humaid AlQassimi";
      userEmail = "git@huma.id";
      extraConfig = {
        core.editor = "nvim";
	pull.rebase = "true";
	init.defaultBranch = "master";
	format.signoff = true;
	url = {
          "git@github.com:".insteadOf = "https://github.com/";
	  "git@git.sr.ht:".insteadOf = "https://git.sr.ht/";
	};
      };
    };
  };

  documentation = {
    enable = true;
    nixos.enable = true;
    man.enable = true;
    man.generateCaches = true;
    info.enable = true;
    doc.enable = true;
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  programs = {
    mtr.enable = true;
    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };
  };

  nixpkgs.config.allowUnfree = true;
  nix.allowedUsers = [ "humaid" ];
}

