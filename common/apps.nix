# This contains settings to provide a graphical system.
{ config, pkgs, lib, ... }:
with lib;
let
    cfg = config.hsys;
in
{
  options.hsys.getSystemTools =mkOption {
    description= "Installs basic system tools";
    type= types.bool;
    default= true;
  };
  options.hsys.getCliTools =mkOption {
    description= "Installs favourite CLI tools";
    type= types.bool;
    default= true;
  };
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
    (mkIf cfg.getSystemTools { # Basic system tools for all systems
      environment.systemPackages = with pkgs; [
        zsh
        zsh-autosuggestions
        neovim
        wget
        tmux
        ranger
        htop
        wget
        curl
        tcpdump
        file
        lsof
        strace
        xz
        zip
        lz4
        unzip
        rsync
        tree
        pwgen
        jq
        ripgrep
        ripgrep-all
        usbutils
        pciutils
        gitAndTools.gitFull
        xclip
        killall
        file
        du-dust
	dig
	nixpkgs-fmt
      ];

      programs.neovim.viAlias = true;
      programs.neovim.vimAlias = true;

      # Locate
      services.locate = {
        locate = pkgs.plocate;
      };

      environment.variables = {
        EDITOR = "nvim";
        VISUAL = "nvim";
      };
    })
    (mkIf cfg.getCliTools { # All development and programming tools/utilities
      environment.systemPackages = with pkgs; [
        # CLI productivity
        jpegoptim
        optipng
        languagetool
        aspell
        aspellDicts.ar
        aspellDicts.en
        aspellDicts.fi

        # CLI productivity
        jpegoptim
        optipng
        languagetool
      ];
    })
    (mkIf cfg.getDevTools { # All development and programming tools/utilities
      environment.systemPackages = with pkgs; [
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
	dmtx
      ];
    })
  ];

}
