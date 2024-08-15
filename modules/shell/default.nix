{
  config,
  pkgs,
  lib,
  vars,
  ...
}: let
  cfg = config.sifr.shell;
  lscolors = fetchGit {
    url = "https://github.com/trapd00r/LS_COLORS";
    rev = "a283d79dcbb23a8679f4b1a07d04a80cab01c0ba"; # Dec 14, 2023
  };
  zsh-extract = fetchGit {
    url = "https://github.com/le0me55i/zsh-extract";
    # Project is stagnant (Dec 2019), though works perfectly fine.
    rev = "ecad02d5dbd9468e0f77181c4e0786cdcd6127a9";
  };
in {
  options.sifr.shell.zsh = lib.mkOption {
    description = "Enables zsh with customisations";
    type = lib.types.bool;
    default = true;
  };
  config = lib.mkMerge [
    # Linux-only configurations
    (lib.mkIf (cfg.zsh && pkgs.stdenv.isLinux) {
      home-manager.users."${vars.user}" = {
        # none
      };
    })
    (lib.mkIf cfg.zsh {
      programs.zsh.enable = true;
      users.users."${vars.user}".shell = pkgs.zsh;
      home-manager.users."${vars.user}" = {
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
            bindkey '^[[P' delete-char                        # fix delete for st
            bindkey '^[[1;5C' forward-word                    # ctrl + ->
            bindkey '^[[1;5D' backward-word                   # ctrl + <-
            bindkey '^[[5~' beginning-of-buffer-or-history    # page up
            bindkey '^[[6~' end-of-buffer-or-history          # page down
            bindkey '^[[H' beginning-of-line                  # home
            bindkey '^[[F' end-of-line                        # end
            bindkey '^[[Z' undo                               # shift + tab undo last action
            bindkey '^f' vi-forward-char                      # for auto-complete

            source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh
            source ${pkgs.zsh-nix-shell}/share/zsh-nix-shell/nix-shell.plugin.zsh
            source ${lscolors}/lscolors.sh
            source ${zsh-extract}/extract.plugin.zsh
            export PATH=/opt/homebrew/bin:$PATH

            function ghafa-rebuild() {
              nixos-rebuild --flake .#lenovo-x1-carbon-gen11-debug --target-host root@ghafa --fast boot --log-format internal-json -v |& nom --json  && ssh root@ghafa reboot
            }
            function ghafa-orin-rebuild() {
              nixos-rebuild --flake .#nvidia-jetson-orin-agx-debug --target-host root@ghafa-orin --fast boot --log-format internal-json -v |& nom --json  && ssh root@ghafa-orin reboot
            }

            function ntp() {
              chronyd -Q -t 3 "server $1 iburst maxsamples 1"
            }
            function nts() {
              chronyd -Q -t 3 "server $1 iburst nts maxsamples 1"
            }

            function mkcd() {
              if [[ -z $1 ]]; then
                echo "Usage: mkcd <directory>"
                return 1
              fi
              mkdir -p $1 && cd $1
            }

            echo "$fg[cyan]Welcome back ${config.sifr.fullname} to your local terminal."
          '';
          shellAliases = {
            ka = "killall";
            vim = "nvim";
            vi = "nvim";
            v = "nvim";
            vf = "nvim $(fzf)";
            recent = "ls -ltch";
            q = "exit";
            c = "clear";
            t = "tmux";
            #sudo = "doas";
            doas = "sudo";
            #ptop = "sudo powertop";
            #bsd2 = "licensor BSD-2-Clause \"${config.sifr.fullname}\" > LICENSE";
            #agpl = "licensor AGPL-3.0 \"${config.sifr.fullname}\" > LICENSE";
            yt = "yt-dlp --add-metadata -ic";
            yta = "yt-dlp -f bestaudio/best --add-metadata -xic";
            pf = "pfetch";
            pgr = "ps aux | grep";
            open = "xdg-open";
            ex = "extract";

            # Git
            g = "git";
            ga = "git add";
            gad = "git add .";
            gc = "git commit -s";
            gs = "git status";
            gd = "git diff";
            gds = "git diff --staged";
            gpl = "git pull";
            gps = "git push";
            gr = "git restore";
            grs = "git restore --staged";
            gco = "git checkout";
            gcb = "git checkout -b";
            gpa = "git remote | xargs -L1 git push --all";

            # Always recursive
            cp = "cp -r";
            scp = "scp -r";

            # Less verbosity
            bc = "bc -ql";

            turbo = "sudo cpupower -c all frequency-set -g performance";
            unturbo = "sudo cpupower -c all frequency-set -g powersave";

            units = "units --history /dev/null";

            # Nix
            #rebuild = "doas nixos-rebuild switch";
            #rebuild-offline = "doas nixos-rebuild switch --option substitute false";
            xs = "nix search nixpkgs";
            np = "nix-shell -p";
            nr = "nix repl";
            nrp = "nix repl '<nixpkgs>'";
            nrb = "sudo nixos-rebuild switch --flake github:humaidq/dotfiles#$(hostname) --refresh --log-format internal-json -v |& nom --json";

            # Better ls
            ls = lib.mkForce "eza --group-directories-first";
            l = "eza -a -l -h --git --group-directories-first";

            # set color=always for some commands
            grep = "grep --color=always";
            diff = "diff --color=always";
            ip = "ip --color=always";
            tree = "tree -C";
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

        # ls replacement
        programs.eza = {
          enable = true;
          enableZshIntegration = true;
        };
        programs.zoxide = {
          enable = true;
          enableZshIntegration = true;
        };
      };
    })
  ];
}
