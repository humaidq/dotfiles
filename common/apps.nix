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
        htop
        wget
        curl
        file
        gitAndTools.gitFull
        lsof
        xz
        zip
        pstree
        lz4
        unzip
        rsync
        tree
        jq
        fd
        acpi
        units
        bc
        usbutils
        pciutils
        killall
        file
        dig
        pv
        nixpkgs-fmt
        pfetch
        #(import ../pkgs/ufetch.nix)
      ];


      # Ensure zsh is recognised as a system shell.
      environment.shells = [ pkgs.zsh ];

      environment.variables = {
        EDITOR = "nvim";
        VISUAL = "nvim";
        TERMINAL = "st";
        BROWSER = "firefox";
        #PAGER = "bat --paging=always";

        # clean up
        #XAUTHORITY = "$XDG_RUNTIME_DIR/xauthority";
        GTK2_RC_FILES = "$XDG_CONFIG_HOME/gtk-2.0/gtkrc-2.0";
        LESSHISTFILE = "-";
        SQLITE_HISTORY = "/tmp/sqlite_history";
        WGETRC = "$XDG_CONFIG_HOME/wget/wgetrc";
        TMUX_TMPDIR = "$XDG_RUNTIME_DIR";
        #CARGO_HOME="$XDG_DATA_HOME/cargo";
        GOPATH = "$HOME/repos/go";
        #HISTFILE = "$XDG_DATA_HOME/history";

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
        ispell
        aspell
        aspellDicts.ar
        aspellDicts.en
        aspellDicts.fi
        #youtube-dl
        yt-dlp
        biber
        nixos-generators
        tcpdump
        strace
        netcat
        nmap
        pwgen
        du-dust
        bombadillo
        gping
        traceroute
        borgbackup
        qrencode
        gnupatch
        pandoc
        sshfs
        ripgrep
        ripgrep-all
        aria2
        tmux
        #ranger # TODO derecated
        lf
        scc
        fzf
        signify

        # CLI productivity
        jpegoptim
        optipng
        languagetool
      ];

      # Locate
      services.locate = {
        enable = true;
        locate = pkgs.plocate;
        interval = "daily";
        localuser = null; # for 22.05
      };
    })
    (mkIf cfg.getDevTools {
      # All development and programming tools/utilities
      environment.systemPackages = with pkgs; [
        #go
        git-privacy
        unstable.go_1_18
        unstable.gopls
        unstable.delve
        gcc
        cargo
        hare
        rustc
        rust-analyzer
        rustfmt
        pkg-config
        gnupg
        gdb
        bvi
        tealdeer
        jre
        jdk
        licensor

        plantuml
        graphviz
        texlive.combined.scheme-full
        shellcheck
        gnumake
        cmake
        cmake-language-server
        lua
        sumneko-lua-language-server
        bat
        ffmpeg-full
        lm_sensors
        minify
        mdbook
        unstable.hugo
        sfeed
        dmtx-utils
        python38Full
        pyright
        sqlite
        rlwrap
        vscodium
      ];
      # This would set up proper wireshark group
      programs.wireshark.enable = true;
    })
  ];
}
