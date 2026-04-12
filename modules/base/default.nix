{
  config,
  pkgs,
  lib,
  vars,
  inputs,
  ...
}:
let
  cfg = config.sifr;
in
{
  imports = [
    inputs.sops-nix.nixosModules.sops
    inputs.home-manager.nixosModules.home-manager
    inputs.srvos.nixosModules.mixins-nix-experimental
    ./options
    ./baseplus.nix
    ./applications
    ./development
    ./system
    ./user
    ../home-server
  ];

  config = {
    assertions = [
      {
        assertion = cfg.timezone != null;
        message = "sifr.timezone must be set";
      }
      {
        assertion = cfg.username != null;
        message = "sifr.username must be set";
      }
      {
        assertion = cfg.fullname != null;
        message = "sifr.fullname must be set";
      }
      {
        assertion = cfg.gitEmail != null;
        message = "sifr.gitEmail must be set";
      }
      {
        assertion = cfg.projectFlake != null;
        message = "sifr.projectFlake must be set";
      }
    ];

    users = {
      mutableUsers = false;
      users.${vars.user} = {
        isNormalUser = true;
        uid = 1000;
        extraGroups = [
          "plugdev"
          "dialout"
          "video"
          "audio"
          "disk"
          "networkmanager"
          "wheel"
          "kvm"
        ];
        description = cfg.fullname;
        openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
      };
      groups.plugdev = { };
    };

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      sharedModules = [
        inputs.nixvim.homeModules.nixvim
      ]
      ++ lib.optionals (pkgs.stdenv.hostPlatform.system != "riscv64-linux") [
        inputs.nix-index-database.homeModules.nix-index
      ];
      users.${vars.user} = {
        home.stateVersion = "23.05";
        home.sessionPath = [ "$HOME/.bin" ];
      };
    };

    environment.systemPackages =
      (with pkgs; [
        ghostty.terminfo
        acpi
        bc
        curl
        dig
        ethtool
        fd
        fd
        file
        git
        htop
        iotop
        killall
        lsof
        lz4
        nix-output-monitor
        numactl
        parted
        pciutils
        pstree
        pv
        rsync
        smartmontools
        sops
        sysstat
        tcpdump
        tmux
        trace-cmd
        tree
        units
        unzip
        usbutils
        wget
        xz
        zip
      ])
      ++ lib.optionals pkgs.stdenv.isx86_64 (
        with pkgs;
        [
          cpuid
          msr-tools
          tiptop
        ]
      );

    environment.shells = [ pkgs.zsh ];

    security.sudo-rs.enable = true;
    security.sudo.extraConfig = ''
      Defaults lecture = never
    '';

    environment.variables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
      BROWSER = lib.mkDefault "echo";
      OPENER = "xdg-open";
      GTK2_RC_FILES = "$XDG_CONFIG_HOME/gtk-2.0/gtkrc-2.0";
      LESSHISTFILE = "-";
      SQLITE_HISTORY = "/tmp/sqlite_history";
      TMUX_TMPDIR = "$XDG_RUNTIME_DIR";
      GOPATH = "$HOME/repos/go";
      LC_ALL = "en_US.UTF-8";
      DO_NOT_TRACK = "1";
      _JAVA_AWT_WM_NONREPARENTING = "1";
    };

    time.timeZone = cfg.timezone;
    i18n.defaultLocale = "en_GB.UTF-8";

    nix = {
      settings = {
        experimental-features = [
          "pipe-operators"
          "auto-allocate-uids"
        ];
        extra-experimental-features = [ ];
        allowed-users = [
          cfg.username
        ];
        trusted-users = [
          "root"
          cfg.username
        ];
        auto-optimise-store = true;
      };

      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };

      optimise = {
        automatic = true;
      };
    };

    fonts.packages = [ pkgs.spleen ];
    console.font = "${pkgs.spleen}/share/consolefonts/spleen-12x24.psfu";

    services.getty = {
      greetingLine = lib.mkOverride 50 ''<<< Welcome to ${config.networking.hostName} (\l) >>>'';
    };

    hardware.enableAllFirmware = true;

    nixpkgs = {
      config = {
        allowUnfree = true;
        permittedInsecurePackages = [
          "aspnetcore-runtime-wrapped-6.0.36"
          "aspnetcore-runtime-6.0.36"
          "dotnet-sdk-wrapped-6.0.428"
          "dotnet-sdk-6.0.428"
        ];
      };

      overlays = [
        (final: prev: {
          unstable = import inputs.nixpkgs-unstable {
            inherit (final.stdenv.hostPlatform) system;
            config.allowUnfree = true;
          };

          liquidctl = import ../../overlays/liquidctl { inherit prev; };

          ufetch = pkgs.callPackage ../../overlays/ufetch { };

          nwjs = prev.nwjs.overrideAttrs {
            version = "0.84.0";
            src = prev.fetchurl {
              url = "https://dl.nwjs.io/v0.84.0/nwjs-v0.84.0-linux-x64.tar.gz";
              hash = "sha256-VIygMzCPTKzLr47bG1DYy/zj0OxsjGcms0G1BkI/TEI=";
            };
          };
        })
      ];
    };
  };
}
