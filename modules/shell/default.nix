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
    rev = "a283d79dcbb23a8679f4b1a07d04a80cab01c0ba"; # Dec 14, 2023
  };
  # fish specific plugins can be added here in the future
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
    #ptop = "sudo powertop";
    #bsd2 = "licensor BSD-2-Clause \"${config.sifr.fullname}\" > LICENSE";
    #agpl = "licensor AGPL-3.0 \"${config.sifr.fullname}\" > LICENSE";
    yt = "yt-dlp --add-metadata -ic";
    yta = "yt-dlp -f bestaudio/best --add-metadata -xic";
    pf = "pfetch";
    pgr = "ps aux | grep";
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
  options.sifr.shell.fish = lib.mkOption {
    description = "Enables fish with customisations";
    type = lib.types.bool;
    default = true;
  };
  config = lib.mkMerge [
    # Linux-only configurations
    (lib.mkIf (cfg.fish && pkgs.stdenv.isLinux) {
      home-manager.users."${vars.user}" = {
        # none
      };
    })
    (lib.mkIf cfg.fish {
      documentation.man.generateCaches = false; # speed up rebuild
      programs.fish.enable = true;
      users.users."${vars.user}".shell = pkgs.fish;
      home-manager.users."${vars.user}" = {
        programs.fish = {
          enable = true;
          shellAliases = shellAliases // {
            nrb = "sudo nixos-rebuild switch --flake github:humaidq/dotfiles#$(hostname) --refresh --log-format internal-json -v --show-trace &| nom --json";
            nrbl = "sudo nixos-rebuild switch --flake .#$(hostname) --refresh --log-format internal-json -v --show-trace &| nom --json";
            nrblo = "sudo nixos-rebuild switch --flake .#$(hostname) --refresh --log-format internal-json -v --option substitute false --show-trace &| nom --json";
          };
          functions = {
            ghafa-rebuild = ''
              nixos-rebuild --flake .#lenovo-x1-carbon-gen11-debug --target-host root@ghafa --fast boot --log-format internal-json -v --show-trace &| nom --json  && ssh root@ghafa reboot
            '';
            ghafa-orin-rebuild = ''
              nixos-rebuild --flake .#nvidia-jetson-orin-agx-debug --target-host root@ghafa-orin --fast boot --log-format internal-json -v --show-trace &| nom --json  && ssh root@ghafa-orin reboot
            '';

            ntp = ''
              chronyd -Q -t 3 "server $1 iburst maxsamples 1"
            '';
            nts = ''
              chronyd -Q -t 3 "server $1 iburst nts maxsamples 1"
            '';

            e = ''
              args="-c"
              if [[ -n $DISPLAY ]]; then
                 args="-t"
              fi

              emacsclient $args '$1'
            '';

            mkcd = ''
              if test -z "$argv"; then
                echo "Usage: mkcd <directory>"
                return 1
              end
              mkdir -p "$argv"; and cd "$argv"
            '';
          };
          interactiveShellInit = ''
            set fish_greeting
          '';
        };
        # ls replacement
        programs.eza = {
          enable = true;
          enableFishIntegration = true;
        };
        programs.zoxide = {
          enable = true;
          enableFishIntegration = true;
        };
      };
    })
  ];
}
