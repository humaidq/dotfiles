# User and home-manager configurations goes here.
{ config, pkgs, lib, ... }:
{
  imports = [
    <home-manager/nixos>
    ./firefox.nix
  ];


  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.humaid = {
    isNormalUser = true;
    # wheel removed since we use doas
    extraGroups = [ "plugdev" "dialout" "wireshark" "video" "audio" "docker"
      "vboxusers" ];
    description = "Humaid AlQassimi";
    shell = pkgs.zsh;
  };

  home-manager.users.humaid = { pkgs, lib, ... }:
    let
      mkTuple = lib.hm.gvariant.mkTuple;
      nur = import (builtins.fetchTarball "https://github.com/nix-community/NUR/archive/master.tar.gz") {
        inherit pkgs;
      };
      lscolors = fetchGit {
        url = "https://github.com/trapd00r/LS_COLORS";
        rev = "14ed0f0e7c8e531bbb4adaae799521cdd8acfbd3"; # 13 Mar, 2022
      };
    in
    {
      home.stateVersion = "21.11";
      nixpkgs.config.allowUnfree = true; # for firefox ext.
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
        #mime.defaultApplications = {
        #  image/png = [
        #    "img.desktop"
        #  ];

        #};
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
      };

      # Manage Firefox
      programs.tmux = {
        enable = true;
        # This fixes esc delay issue with vim
        escapeTime = 0;
        # Use vi-like keys to move in scroll mode
        keyMode = "vi";
        clock24 = false;
        extraConfig = "set -g default-terminal \"xterm-256color\"";
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

          # setup sensible options
          setopt interactivecomments
          setopt magicequalsubst
          setopt nonomatch
          setopt notify
          setopt numericglobsort
          setopt promptsubst

          # enable completion features
          autoload -Uz compinit
          compinit -d ~/.cache/zcompdump
          zstyle ':completion:*:*:*:*:*' menu select
          zstyle ':completion:*' auto-description 'specify: %d'
          zstyle ':completion:*' completer _expand _complete
          zstyle ':completion:*' format 'Completing %d'
          zstyle ':completion:*' group-name \'\'
          zstyle ':completion:*' list-colors \'\'
          zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
          zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
          zstyle ':completion:*' rehash true
          zstyle ':completion:*' select-prompt %SScrolling active: current selection at %p%s
          zstyle ':completion:*' use-compctl false
          zstyle ':completion:*' verbose true
          zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'
          
          # History configurations
          HISTFILE=~/.zsh_history
          HISTSIZE=1000
          SAVEHIST=2000
          setopt hist_expire_dups_first # delete duplicates first when HISTFILE size exceeds HISTSIZE
          setopt hist_ignore_dups       # ignore duplicated commands history list
          setopt hist_ignore_space      # ignore commands that start with space
          setopt hist_verify            # show command with history expansion to user before running it
          #setopt share_history         # share command history data

          # configure key keybindings
          bindkey -e                                        # emacs key bindings
          bindkey ' ' magic-space                           # do history expansion on space
          bindkey '^U' backward-kill-line                   # ctrl + U
          bindkey '^[[3;5~' kill-word                       # ctrl + Supr
          bindkey '^[[3~' delete-char                       # delete
          bindkey '^[[1;5C' forward-word                    # ctrl + ->
          bindkey '^[[1;5D' backward-word                   # ctrl + <-
          bindkey '^[[5~' beginning-of-buffer-or-history    # page up
          bindkey '^[[6~' end-of-buffer-or-history          # page down
          bindkey '^[[H' beginning-of-line                  # home
          bindkey '^[[F' end-of-line                        # end
          bindkey '^[[Z' undo                               # shift + tab undo last action
          bindkey '^f' vi-forward-char

          source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh
          source ${pkgs.zsh-nix-shell}/share/zsh-nix-shell/nix-shell.plugin.zsh
          source ${lscolors}/lscolors.sh
        '';
        shellAliases = {
          rebuild = "doas nixos-rebuild switch";
          ka = "killall";
          g = "git";
          vim = "nvim";
          vi = "nvim";
          v = "nvim";
          xs = "nix search";
          ls = "ls --color=auto -hN --group-directories-first";
          recent = "ls -ltch";
          # set color=auto for some commands
          grep = "grep --color=auto";
          diff = "diff --color=auto";
          ip = "ip --color=auto";
          l = "ls -alhN --color=auto";
          history = "history 0"; # force show all history
        };
        history = {
          size = 10000000;
          #path = "${config.xdg.dataHome}/zsh/history";
        };
        sessionVariables = {
          EDITOR = "nvim";
        };
      };

      # dconf (gsettings) for Gnome applications
      dconf.settings = {
        "org/gnome/shell" = {
          favorite-apps = [
            "firefox.desktop"
            "mozilla-thunderbird.desktop"
            "org.gnome.Terminal.desktop"
            "org.gnome.Nautilus.desktop"
          ];
        };
        "org/gnome/desktop/interface" = {
          gtk-theme = "Adwaita-dark";
          clock-format = "12h";
          show-battery-percentage = true;
        };
        "org/gnome/desktop/sound" = {
          allow-volume-above-100-percent = true;
        };
        "org/gnome/desktop/wm/preferences" = {
          # Add minimise button, use Inter font
          button-layout = "appmenu:minimize,close";
          titlebar-font = "Inter Semi-Bold 11";
        };
        "org/gnome/desktop/input-sources" = {
          # Add three keyboad layouts (en, ar, fi)
          sources = [ (mkTuple [ "xkb" "us" ]) (mkTuple [ "xkb" "ara" ]) (mkTuple [ "xkb" "fi" ]) ];
          xkb-options = [ "caps:escape" ];
        };
        "org/gnome/desktop/media-handling" = {
          # Don't mount devices when plugged in
          automount = false;
          automount-open = false;
          autorun-never = true;
        };
        "org/gnome/desktop/interface" = {
          # Inter font
          document-font-name = "Inter 11";
          font-name = "Inter 11";
        };
      };
      gtk = {
        enable = true;
        theme.name = "Adwaita-dark";
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

      # Custom neovim setup
      # We use paq for managing neovim packages.
      xdg.dataFile."nvim/site/pack/paqs/start/paq-nvim".source = fetchGit {
        url = "https://github.com/savq/paq-nvim";
        rev = "6caab059bc15cc61afc7aa7e0515ee06eb550bcf";
      };

      # Symlink our neovim configuration files
      xdg.configFile."nvim/init.lua".source = ./nvim/init.lua;
      xdg.configFile."nvim/lua".source = ./nvim/lua;

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
          commit.verbose = "yes";
          sendmail.smtpserver = "smtp.migadu.com";
          sendmail.smtpuser = "git@humaidq.ae";
          sendmail.smtpencryption = "tls";
          sendmail.smtpserverport = "587";
          url = {
            #"git@github.com:".insteadOf = "https://github.com/";
            #"git@git.sr.ht:".insteadOf = "https://git.sr.ht/";
          };
        };
      };
    };
}
