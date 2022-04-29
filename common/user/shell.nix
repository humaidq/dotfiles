{ pkgs, lib, ... }:
let
  lscolors = fetchGit {
    url = "https://github.com/trapd00r/LS_COLORS";
    rev = "14ed0f0e7c8e531bbb4adaae799521cdd8acfbd3"; # 13 Mar, 2022
  };
  lname = "Humaid AlQassimi"; # Legal name for licensor
in
{
  programs.zsh = {
    enable = true;
    dotDir = ".config/zsh";
    autocd = true;
    enableVteIntegration = true;
    initExtra = ''
      # Load colours and set prompt
      autoload -U colors && colors
      if [[ -n "$NIX_SHELL_PACKAGES" ]]; then
        ps_nix="$fg[cyan]{$(echo $NIX_SHELL_PACKAGES | tr " " "," )} "
      fi
      PS1="$ps_nix%B%{$fg[red]%}[%{$fg[yellow]%}%n%{$fg[green]%}@%{$fg[blue]%}%M %{$fg[magenta]%}%~%{$fg[red]%}]%{$reset_color%}$%b "

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

      export PATH=$PATH:~/.bin

      source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh
      source ${pkgs.zsh-nix-shell}/share/zsh-nix-shell/nix-shell.plugin.zsh
      source ${lscolors}/lscolors.sh

      function mkcd() {
        mkdir -p $1 && cd $1
      }
      echo "$fg[cyan]Welcome back Humaid to your local terminal."
    '';
    shellAliases = {
      ka = "killall";
      g = "git";
      vim = "nvim";
      vi = "nvim";
      v = "nvim";
      recent = "ls -ltch";
      q = "exit";
      x = "clear";
      t = "tmux";
      sudo = "doas";
      ptop = "doas powertop";
      gpa = "git remote | xargs -L1 git push --all";
      bsd2 = "licensor BSD-2-Clause \"${lname}\" > LICENSE";
      agpl = "licensor AGPL-3.0 \"${lname}\" > LICENSE";
      yt = "youtube-dl --add-metadata -ic";
      yta = "youtube-dl --add-metadata -xic";
      
      turbo = "doas cpupower -c all frequency-set -g performance";
      unturbo = "doas cpupower -c all frequency-set -g powersave";

      units = "units --history /dev/null";

      # Nix
      rebuild = "doas nixos-rebuild switch";
      rebuild-offline = "doas nixos-rebuild switch --option substitute false";
      xs = "nix search";
      np = "nix-shell -p";
      nr = "nix-repl";
      nrp = "nix-repl '<nixpkgs>'";

      # set color=auto for some commands
      ls = "ls --color=auto -hN --group-directories-first";
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
}
