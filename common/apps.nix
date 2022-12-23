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
        # shell related
        zsh
        zsh-autosuggestions
        zsh-nix-shell

        # utilities
        neovim
        wget
        htop
        gitAndTools.gitFull
        rsync
        bc
        units
        pfetch
        nixpkgs-fmt

        # packages that must come with every Linux system
        curl
        lsof
        xz
        zip
        pstree
        lz4
        unzip
        tree
        jq
        fd
        acpi
        usbutils
        pciutils
        killall
        file
        dig
        pv
      ];

      # Ensure zsh is recognised as a system shell.
      environment.shells = [ pkgs.zsh ];

      environment.variables = {
        EDITOR = "nvim";
        VISUAL = "nvim";
        TERMINAL = "alacritty";
        BROWSER = "firefox";

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

        # spell checking
        languagetool
        ispell
        aspell
        aspellDicts.ar
        aspellDicts.en
        aspellDicts.fi

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
        sshfs
        ripgrep
        pandoc
        ripgrep-all
        aria2
        tmux
        lf
        scc
        fzf
        signify
        lm_sensors
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
        # compilers, interpreters, runtimes, etc
        go
        gcc
        hare
        rustc
        jre
        jdk
        lua
        python38Full

        # utilities
        ffmpeg-full
        unstable.delve
        git-privacy
        gdb
        bvi
        minify
        pkg-config
        licensor
        gnupg
        bat
        sqlite
        dmtx-utils
        rlwrap

        # build tools
        gnumake
        cmake
        cargo

        # documentation, generators
        mdbook
        unstable.hugo
        plantuml
        graphviz
        texlive.combined.scheme-full
        tectonic

        # language servers, checkers, formatters
        shellcheck
        sumneko-lua-language-server
        cmake-language-server
        pyright
        rust-analyzer
        rustfmt
        gopls
      ];
    })
  ];
}
