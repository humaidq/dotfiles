{
  config,
  pkgs,
  unstable,
  home-manager,
  lib,
  vars,
  ...
}:
with lib; let
  cfg = config.sifr.profiles;
  desktopEntry = name: command: {
    executable = true;
    text = ''
      [Desktop Entry]
      Type=Application
      Name=${name}
      Exec=${command}
    '';
  };
in {
  options.sifr.profiles.base = mkOption {
    description = "Sifr minimal base for all systems";
    type = types.bool;
    default = pkgs.stdenv.isLinux;
  };
  options.sifr.profiles.basePlus = mkOption {
    description = "Additional productivity command-line tools";
    type = types.bool;
    default = false;
  };
  config = mkMerge [
    (mkIf cfg.base {
      environment.systemPackages = with pkgs; [
        # shell related
        zsh
        zsh-autosuggestions
        direnv
        zsh-nix-shell

        # utilities
        neovim
        wget
        htop
        gitMinimal
        rsync
        bc
        units
        pfetch

        # packages that must come with every Linux system
        curl
        lsof
        xz
        zip
        pstree
        lz4
        unzip
        tree
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
      environment.shells = [pkgs.zsh];

      environment.variables = {
        EDITOR = "nvim";
        VISUAL = "nvim";
        TERMINAL = "alacritty";
        BROWSER = "firefox";

        # clean up
        #XAUTHORITY = "$XDG_RUNTIME_DIR/xauthority"; # breaking DMs
        GTK2_RC_FILES = "$XDG_CONFIG_HOME/gtk-2.0/gtkrc-2.0";
        LESSHISTFILE = "-";
        SQLITE_HISTORY = "/tmp/sqlite_history";
        #WGETRC = "$XDG_CONFIG_HOME/wget/wgetrc";
        TMUX_TMPDIR = "$XDG_RUNTIME_DIR";
        GOPATH = "$HOME/repos/go";
        #CARGO_HOME="$XDG_DATA_HOME/cargo";
        #HISTFILE = "$XDG_DATA_HOME/history";

        LC_ALL = "en_US.UTF-8";
        DO_NOT_TRACK = "1";

        # Java issue fix
        _JAVA_AWT_WM_NONREPARENTING = "1";
      };
    })
    (mkIf cfg.basePlus {
      environment.systemPackages = with pkgs; [
        # File processing
        jpegoptim
        optipng

        # Spell checking
        languagetool
        ispell
        aspell
        aspellDicts.ar
        aspellDicts.en
        aspellDicts.fi

        # Other productivity
        yt-dlp
        biber
        tcpdump
        strace
        netcat
        nmap
        pwgen
        du-dust
        gping
        traceroute
        borgbackup
        qrencode
        gnupatch
        ripgrep
        tmux
        lf
        sshfs
        jq

        # TODO move to laptop config
        lm_sensors
      ];

      # Locate
      services.locate = {
        enable = true;
        package = pkgs.plocate;
        interval = "daily";
        localuser = null; # for 22.05
        # Sometimes indexing hgfs on VMWare causing CPU to go 100%
        prunePaths = [ "/mnt" ];
      };

      # Track highest uptime! :)
      services.uptimed.enable = true;

      home-manager.users."${vars.user}" = {
        programs = {
          ssh = {
            enable = true;
            matchBlocks."*" = {
              extraOptions.IdentityAgent = "~/.1password/agent.sock";
            };
          };
          tmux = {
            enable = true;
            # This fixes esc delay issue with vim
            escapeTime = 0;
            # Use vi-like keys to move in scroll mode
            keyMode = "vi";
            clock24 = false;
            extraConfig = ''
              set-option -sa terminal-features ',*:RGB'
            '';
          };
          lf = {
            enable = true;
            extraConfig = "set shell sh";
            commands = {
              open = ''
                  ''${{
                case $(file --mime-type "$(readlink -f $f)" -b) in
                  text/*|application/json|inode/x-empty) $EDITOR $fx ;;
                  application/*) nvim $fx ;;
                  *) for f in $fx; do setsid $OPENER $f > /dev/null 2> /dev/null & done ;;
                esac
                }}
              '';
            };
            cmdKeybindings = {
              "<enter>" = "open";
            };
          };
        };
        services.gpg-agent = {
          enable = true;
          enableZshIntegration = true;
          #pinentryFlavor = "qt";
        };

        xdg = {
          enable = true;
          mimeApps.enable = true;
          #portal = {
          #  enable = true;
          #  extraPortals = with pkgs; [
          #    xdg-desktop-portal-wlr
          #    xdg-desktop-portal-gtk
          #  ];
          #  gtkUsePortal = true;
          #};
          mimeApps.defaultApplications = {
            "inode/directory" = ["file.desktop"];

            # Images
            "image/png" = ["img.desktop"];
            "image/jpeg" = ["img.desktop"];
            "image/gif" = ["img.desktop"];

            # Text
            "text/x-shellscript" = ["text.desktop"];
            "text/x-c" = ["text.desktop"];
            "text/x-lisp" = ["text.desktop"];
            "text/html" = ["text.desktop"];
            "text/plain" = ["text.desktop"];

            # PDF
            "application/pdf" = ["pdf.desktop"];
            "application/postscript" = ["pdf.desktop"];

            # Videos
            "video/mp4" = ["video.desktop"];
            "video/x-msvideo" = ["video.desktop"];
            "video/quicktime" = ["video.desktop"];
          };
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
          configFile."user-dirs.locale".text = "en_GB";

          # prevent home-manager from failing after rebuild
          configFile."mimeapps.list".force = true;

          # Desktop entry aliases
          #dataFile."applications/img.desktop" =
          #  desktopEntry "Image Viewer" "${pkgs.nsxiv}/bin/nsxiv -a %f";

          #dataFile."applications/file.desktop" =
          #  desktopEntry "File Manager" "${pkgs.st}/bin/st -e lf %u";

          #dataFile."applications/text.desktop" =
          #  desktopEntry "Text Editor" "${pkgs.alacritty}/bin/alacritty -e nvim %f";

          #dataFile."applications/pdf.desktop" =
          #  desktopEntry "PDF Viewer" "${pkgs.zathura}/bin/zathura %u";

          #dataFile."applications/video.desktop" =
          #  desktopEntry "Video Player" "${pkgs.vlc}/bin/vlc %u";
        };
      }; # end of home-manager
    })
  ];
}
