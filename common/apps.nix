# This contains settings to provide a graphical system.
{ config, pkgs, lib, ... }:
with lib;
let
  cfg = config.hsys;
in
{
  options.hsys.getSystemTools = mkOption {
    description = "Installs basic system tools";
    type = types.bool;
    default = true;
  };
  options.hsys.getCliTools = mkOption {
    description = "Installs favourite CLI tools";
    type = types.bool;
    default = true;
  };
  options.hsys.getDevTools = mkOption {
    description = "Installs development tools";
    type = types.bool;
    default = false;
  };
  #options.hsys.getTools =mkOption {
  #  description: "Installs development tools";
  #  type: types.bool;
  #  default: false;
  #};

  config = mkMerge [
    (mkIf cfg.getSystemTools {
      # Basic system tools for all systems
      environment.systemPackages = with pkgs; [
        zsh
        zsh-autosuggestions
        zsh-nix-shell
        neovim
        wget
        tmux
        ranger
        lf
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
        acpi
        units
        bc
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
        shellcheck
        borgbackup
      ];

      # Locate
      services.locate = {
        enable = true;
        locate = pkgs.plocate;
        interval = "daily";
      };

      environment.variables = {
        EDITOR = "nvim";
        VISUAL = "nvim";
        TERMINAL = "st";
        BROWSER = "firefox";

        # clean up
        XAUTHORITY = "$XDG_RUNTIME_DIR/xauthority";
        GTK2_RC_FILES = "$XDG_CONFIG_HOME/gtk-2.0/gtkrc-2.0";
        LESSHISTFILE = "-";
        WGETRC = "$XDG_CONFIG_HOME/wget/wgetrc";
        TMUX_TMPDIR="$XDG_RUNTIME_DIR";
        CARGO_HOME="$XDG_DATA_HOME/cargo";
        GOPATH="$HOME/repos/go";
        HISTFILE = "$XDG_DATA_HOME/history";

        LC_ALL = "en_US.UTF-8";
        DO_NOT_TRACK = "1";

        # Java issue fix
        _JAVA_AWT_WM_NONREPARENTING = "1";
      };

    })
    (mkIf cfg.getCliTools {
      # All development and programming tools/utilities
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
    (mkIf cfg.getDevTools {
      # All development and programming tools/utilities
      environment.systemPackages = with pkgs; [
        go
        gopls
        gcc
        gnupg
        gdb
        bvi
        plantuml
        gnumake
        bat
        ffmpeg
        lm_sensors
        minify
        mdbook
        hugo
        dmtx-utils
        python38Full
      ];
      # This would set up proper wireshark group
      programs.wireshark.enable = true;
    })
  ];
}
