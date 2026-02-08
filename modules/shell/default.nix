{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.shell;
  lscolors = fetchGit {
    url = "https://github.com/trapd00r/LS_COLORS";
    rev = "810ce8cac886ac50e75d84fb438b549a1f9478ee"; # Jun 6, 2025
  };
  zsh-extract = fetchGit {
    url = "https://github.com/le0me55i/zsh-extract";
    # Project is stagnant (Dec 2019), though works perfectly fine.
    rev = "ecad02d5dbd9468e0f77181c4e0786cdcd6127a9";
  };
  shellAliases = {
    ka = "killall";
    vim = "nvim";
    vi = "nvim";
    v = "nvim";
    vf = "nvim $(fzf)";
    ef = "emacsclient -t $(fzf)";
    recent = "ls -ltch";
    q = "exit";
    c = "clear";
    t = "tmux";
    tl = "tmux ls";
    ta = "tmux a -t";
    #sudo = "doas";
    doas = "sudo";
    ptop = "sudo powertop";
    #bsd2 = "licensor BSD-2-Clause \"${config.sifr.fullname}\" > LICENSE";
    #agpl = "licensor AGPL-3.0 \"${config.sifr.fullname}\" > LICENSE";
    yt = "yt-dlp --add-metadata -ic";
    yta = "yt-dlp -f bestaudio/best --add-metadata -xic";
    pf = "pfetch";
    pgr = "ps aux | grep";
    ex = "extract";
    uf = "ufetch";

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
in
{
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
      documentation.man.generateCaches = false; # speed up rebuild
      programs.zsh.enable = true;
      users.users."${vars.user}".shell = pkgs.zsh;
      home-manager.users."${vars.user}" = {
        programs.zsh = {
          enable = true;
          dotDir = "${config.home-manager.users.${vars.user}.xdg.configHome}/zsh";
          autocd = true;
          enableVteIntegration = true;
          history = {
            size = 10000000;
            #path = "${config.xdg.dataHome}/zsh/history";
          };
          sessionVariables = {
            EDITOR = "nvim";
          };
          shellAliases = shellAliases // {
            nrb = "sudo nixos-rebuild switch --flake github:humaidq/dotfiles#$(hostname) --refresh --accept-flake-config --log-format internal-json -v --show-trace |& nom --json";
            nrbl = "sudo nixos-rebuild switch --flake .#$(hostname) --refresh --accept-flake-config --log-format internal-json -v --show-trace |& nom --json";
            nrblo = "sudo nixos-rebuild switch --flake .#$(hostname) --refresh --accept-flake-config --log-format internal-json -v --option substitute false --show-trace |& nom --json";
          };
          initContent = ''
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

            # History configurations
            mkdir -p ~/.config/zsh_history
            HISTFILE=~/.config/zsh_history/histfile
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

            function ghafa-rebuild() {
              nixos-rebuild --flake .#lenovo-x1-carbon-gen11-debug --target-host root@ghafa --fast boot --log-format internal-json -v --show-trace |& nom --json  && ssh root@ghafa reboot
            }
            function ghafa-orin-rebuild() {
              nixos-rebuild --flake .#nvidia-jetson-orin-agx-debug --target-host root@ghafa-orin --fast boot --log-format internal-json -v --show-trace |& nom --json  && ssh root@ghafa-orin reboot
            }

            function ntp() {
              chronyd -Q -t 3 "server $1 iburst maxsamples 1"
            }
            function nts() {
              chronyd -Q -t 3 "server $1 iburst nts maxsamples 1"
            }
            function nix-populate() {
              nom build .\#nixosConfigurations.$1.config.system.build.toplevel --keep-going
            }

            function e() {
              args="-c"
              if [[ -n $DISPLAY ]]; then
                 args="-t"
              fi

              emacsclient $args '$1'
            }

            function mkcd() {
              if [[ -z $1 ]]; then
                echo "Usage: mkcd <directory>"
                return 1
              fi
              mkdir -p $1 && cd $1
            }

            # Compression utilities
            function compress() {
              tar -czf "''${1%/}.tar.gz" "''${1%/}"
            }
            alias decompress="tar -xzf"

            # Write ISO file to SD card
            function iso2sd() {
              if [ $# -ne 2 ]; then
                echo "Usage: iso2sd <input_file> <output_device>"
                echo "Example: iso2sd ~/Downloads/ubuntu-25.04-desktop-amd64.iso /dev/sda"
                echo -e "\nAvailable SD cards:"
                lsblk -d -o NAME | grep -E '^sd[a-z]' | awk '{print "/dev/"$1}'
              else
                sudo dd bs=4M status=progress oflag=sync if="$1" of="$2"
                sudo eject $2
              fi
            }

            # Format an entire drive for a single partition using exFAT
            function format-drive() {
              if [ $# -ne 2 ]; then
                echo "Usage: format-drive <device> <name>"
                echo "Example: format-drive /dev/sda 'My Stuff'"
                echo -e "\nAvailable drives:"
                lsblk -d -o NAME -n | awk '{print "/dev/"$1}'
              else
                echo "WARNING: This will completely erase all data on $1 and label it '$2'."
                read -rp "Are you sure you want to continue? (y/N): " confirm

                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                  sudo wipefs -a "$1"
                  sudo dd if=/dev/zero of="$1" bs=1M count=100 status=progress
                  sudo parted -s "$1" mklabel gpt
                  sudo parted -s "$1" mkpart primary 1MiB 100%

                  partition="$([[ $1 == *"nvme"* ]] && echo "''${1}p1" || echo "''${1}1")"
                  sudo partprobe "$1" || true
                  sudo udevadm settle || true

                  sudo mkfs.exfat -n "$2" "$partition"

                  echo "Drive $1 formatted as exFAT and labeled '$2'."
                fi
              fi
            }

            # Transcode a video to a good-balance 1080p that's great for sharing online
            function transcode-video-1080p() {
              ffmpeg -i $1 -vf scale=1920:1080 -c:v libx264 -preset fast -crf 23 -c:a copy ''${1%.*}-1080p.mp4
            }

            # Transcode a video to a good-balance 4K that's great for sharing online
            function transcode-video-4K() {
              ffmpeg -i $1 -c:v libx265 -preset slow -crf 24 -c:a aac -b:a 192k ''${1%.*}-optimized.mp4
            }

            # Transcode any image to JPG image that's great for shrinking wallpapers
            function img2jpg() {
              img="$1"
              shift

              magick "$img" $@ -quality 95 -strip ''${img%.*}-optimized.jpg
            }

            # Transcode any image to JPG image that's great for sharing online without being too big
            function img2jpg-small() {
              img="$1"
              shift

              magick "$img" $@ -resize 1080x\> -quality 95 -strip ''${img%.*}-optimized.jpg
            }

            # Transcode any image to compressed-but-lossless PNG
            function img2png() {
              img="$1"
              shift

              magick "$img" $@ -strip -define png:compression-filter=5 \
                -define png:compression-level=9 \
                -define png:compression-strategy=1 \
                -define png:exclude-chunk=all \
                "''${img%.*}-optimized.png"
            }

            if [[ $OSTYPE == linux* ]]; then
              alias open="xdg-open"
            fi

            uptime_badge() {
              local up_field up_seconds days badge color

              if [[ -r /proc/uptime ]]; then
                # Take only the first field before the first space
                up_field=''${$(< /proc/uptime)%% *}
                # Strip fractional part
                up_seconds=''${up_field%%.*}
              else
                up_seconds=0
              fi

              (( days = up_seconds / 86400 ))

              if (( days >= 5 )); then
                badge="[■■■]"
                color=$fg_bold[red]
              elif (( days >= 3 )); then
                badge="[■■ ]"
                color=$fg[red]
              elif (( days >= 1 )); then
                badge="[■  ]"
                color=$fg[yellow]
              else
                badge="[   ]"
                color=$fg[white]
              fi

              print -n "''${color}''${badge}''${reset_color}"
            }

            uptime_badge
            echo " $fg[cyan]Welcome back ${config.sifr.fullname} to your local terminal."
          '';

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
