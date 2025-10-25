{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.profiles;
in
{
  options.sifr.profiles.base = lib.mkOption {
    description = "Sifr minimal base for all systems";
    type = lib.types.bool;
    default = pkgs.stdenv.isLinux;
  };
  options.sifr.profiles.basePlus = lib.mkOption {
    description = "Additional productivity command-line tools";
    type = lib.types.bool;
    default = false;
  };
  config = lib.mkMerge [
    (lib.mkIf cfg.base {
      environment.systemPackages =
        (with pkgs; [
          # shell related
          fish
          ghostty.terminfo

          # utilities
          wget
          htop
          rsync
          bc
          units
          sops
          git
          tmux

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
          fd
          dig
          pv
          smartmontools
          # Crisis tools https://www.brendangregg.com/blog/2024-03-24/linux-crisis-tools.html
          sysstat
          tcpdump
          trace-cmd
          ethtool
          #cpuid
          numactl
        ])
        ++ lib.optionals pkgs.stdenv.isx86_64 [
          # x86_64 specific tools
          pkgs.cpuid
          pkgs.msr-tools
          pkgs.tiptop
        ];

      # Ensure zsh is recognised as a system shell.
      environment.shells = [
        pkgs.zsh
      ];

      security.sudo-rs = {
        enable = true;
      };
      security.sudo.extraConfig = ''
        Defaults lecture = never
      '';

      environment.variables = {
        EDITOR = "nvim";
        VISUAL = "nvim";
        BROWSER = lib.mkDefault "echo";

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
    (lib.mkIf cfg.basePlus {
      environment.systemPackages = with pkgs; [
        btop

        # File processing
        jpegoptim
        optipng

        # Spell checking
        #languagetool
        #ispell
        #aspell
        #aspellDicts.ar
        #aspellDicts.en
        #aspellDicts.fi

        # Other productivity
        yt-dlp
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
        lf
        sshfs
        jq # json query
        ouch # compression
        hexyl # hex viewer
        poppler-utils
        ufetch

        # TODO move to laptop config
        lm_sensors
      ];

      # Locate
      #services.locate = {
      #  enable = true;
      #  package = pkgs.plocate;
      #  interval = "daily";
      #  localuser = null; # for 22.05
      #  # Sometimes indexing hgfs on VMWare causing CPU to go 100%
      #  prunePaths = [ "/mnt" ];
      #};
      hardware.keyboard.zsa.enable = true;

      # Track highest uptime! :)
      services.uptimed.enable = true;

      home-manager.users."${vars.user}" = {
        programs.ssh.enable = true;
        services.ssh-agent.enable = true;
        programs = {
          tmux = {
            enable = true;

            plugins = with pkgs.tmuxPlugins; [
              sensible
              #resurrect
              #copycat
              #continuum
              #tmux-thumbs
            ];
            # This fixes esc delay issue with vim
            #escapeTime = 0;
            # Use vi-like keys to move in scroll mode
            keyMode = "vi";
            clock24 = false;
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

          fzf = {
            enable = true;
            # https://github.com/brianmcgillion/dotfiles/blob/9d95e3aa57c52a5c6bcec671f13b880f86626bce/home/shell/fzf.nix
            defaultCommand = "git ls-files --cached --others --exclude-standard | fd --type f --type l --hidden --follow --exclude .git";
            defaultOptions = [
              "--reverse"
              "--multi --inline-info --preview='[[ \\$(file --mine {}) =~ binary ]] && echo {} is a binary file || (bat --style=numbers --color=always {} || cat {}) 2>/dev/null | head -300' --preview-window='right:hidden:wrap' --bind='f3:execute(bat --style=numbers {} || less -f {}),f2:toggle-preview,ctrl-d:half-page-down,ctrl-u:half-page-up,ctrl-a:select-all+accept,ctrl-y:execute-silent(echo {+} | pbcopy)'"
            ];
            changeDirWidgetCommand = "fd --type d --hidden --follow --exclude .git"; # ALT_C command
            fileWidgetCommand = "fd --hidden --follow --exclude .git"; # CTRL_T command
          };
        };

        xdg = {
          enable = true;
          mimeApps.enable = true;
          mimeApps.defaultApplications = {
            #"inode/directory" = ["file.desktop"];
            #
            ## Images
            #"image/png" = ["img.desktop"];
            #"image/jpeg" = ["img.desktop"];
            #"image/gif" = ["img.desktop"];
            #
            ## Text
            #"text/x-shellscript" = ["text.desktop"];
            #"text/x-c" = ["text.desktop"];
            #"text/x-lisp" = ["text.desktop"];
            #"text/html" = ["text.desktop"];
            #"text/plain" = ["text.desktop"];
            #
            ## PDF
            #"application/pdf" = ["pdf.desktop"];
            #"application/postscript" = ["pdf.desktop"];
            #
            ## Videos
            #"video/mp4" = ["video.desktop"];
            #"video/x-msvideo" = ["video.desktop"];
            #"video/quicktime" = ["video.desktop"];
          };
          userDirs = {
            enable = true;
            createDirectories = false;
            desktop = "$HOME";
            documents = "$HOME/docs";
            download = "$HOME/inbox/web";
            pictures = "$HOME/docs/pics";
            videos = "$HOME/docs/vids";
            music = "";
            publicShare = "";
            templates = "";
          };
          configFile."user-dirs.locale".text = "en_GB";

          # prevent home-manager from failing after rebuild
          configFile."mimeapps.list".force = true;
          configFile."user-dirs.locale".force = true;
          configFile."user-dirs.dirs".force = true;

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
