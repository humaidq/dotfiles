{
  self,
  inputs,
  lib,
  pkgs,
  vars,
  config,
  ...
}:
let
  # Emacs pgtk rasterises into a buffer at the scale in effect when a frame was
  # created, and never re-renders when that frame moves to a differently-scaled
  # output.  sway then upscales the stale buffer and text goes blurry, which is
  # what happens on every dock/undock between the scale 1 internal panel and the
  # scale 2 externals.  Nudge Emacs to rebuild its frames once the new output
  # layout has settled; see sifr/emacs-rescale-frames in $DOOMDIR/config.el.
  #
  # This used to be `pkill -USR1 -f 'emacs-pgtk-.*/bin/[e]macs'`, which also
  # matched the waiting `emacsclient --create-frame` -- emacsclient installs no
  # SIGUSR1 handler, so the default disposition killed it, the daemon tore down
  # the client's frame, and that raced the rescale we had just asked for.  Half
  # the time the frame went away before it could be rebuilt.  Go through the
  # server socket instead: it reaches the daemon and nothing else, and it runs
  # on the normal command path rather than waiting for the daemon to next
  # consult `special-event-map`.
  rescaleEmacsFrames = "sleep 1 && ${pkgs.emacs30-pgtk}/bin/emacsclient --no-wait --eval '(sifr/emacs-rescale-frames)' >/dev/null 2>&1 || true";
in
{
  imports = [
    self.nixosModules.sifrOS.base
    self.nixosModules.sifrOS.personal.base
    self.nixosModules.sifrOS.laptop
    self.nixosModules.sifrOS.desktop
    self.nixosModules.sifrOS.security
    self.nixosModules.sifrOS.persist
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-x1-13th-gen
    inputs.disko.nixosModules.disko
    # https://github.com/nix-community/lanzaboote/blob/master/docs/QUICK_START.md
    inputs.lanzaboote.nixosModules.lanzaboote
    (import ./hardware.nix)
    (import ./disk.nix)
  ];
  networking.hostName = "anoa";
  networking.hostId = "616e6f61";

  # Nebula keys
  sops.secrets."nebula/crt" = {
    sopsFile = ../../secrets/anoa.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."nebula/key" = {
    sopsFile = ../../secrets/anoa.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."nebula/ssh_host_key" = {
    sopsFile = ../../secrets/anoa.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."borg/ssh_key" = {
    sopsFile = ../../secrets/anoa.yaml;
  };

  sops.secrets."migadu/mehumaid-password" = {
    sopsFile = ../../secrets/anoa.yaml;
    owner = "humaid";
  };
  sops.secrets."dav/password" = {
    sopsFile = ../../secrets/anoa.yaml;
    owner = "humaid";
  };
  sops.secrets."mbzuai-calendar" = {
    sopsFile = ../../secrets/anoa.yaml;
    owner = "humaid";
  };
  sops.secrets."netrc" = {
    sopsFile = ../../secrets/anoa.yaml;
    path = "/home/humaid/.netrc";
    owner = "humaid";
    mode = "0400";
  };

  services.upower.ignoreLid = true;

  users.users.${vars.user}.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYrVNuxuD0F8VJr5AYlhMYEHZui4ANt3AfFJIYejRK4 moshi"
  ];

  sifr = {
    desktop = {
      sway.enable = true;
      enable = true;
      apps = true;
      berkeley.enable = true;
    };
    security = {
      yubikey = true;
    };
    hasGadgetSecrets = true;
    development.enable = true;
    basePlus.enable = true;
    personal = {
      ntp.useNTS = true;
      o11y.client.enable = true;
      focusMode.enable = true;
      moshi.enable = true;
      amateur.enable = true;
      dns.enable = true;
      research.enable = true;
      securityResearch.enable = true;
      netwatch.enable = true;
      work.enable = true;
      university.enable = true;
      tailscale.enable = true;
      net = {
        sifr0 = true;
        node-crt = config.sops.secrets."nebula/crt".path;
        node-key = config.sops.secrets."nebula/key".path;
        ssh-host-key = config.sops.secrets."nebula/ssh_host_key".path;
      };
      rclone = {
        enable = true;
        remote = "oreamnos";
        remotePath = "/mnt/humaid/files";
        mountPath = "docs/files";
        sshUser = "humaid";
        sshKey = "/home/humaid/.ssh/id_ed25519_build";
      };
    };
    applications = {
      chromium.enable = true;
      emacs.enable = true;
    };
    v12n.docker.enable = true;
    v12n.emulation = {
      enable = true;
      systems = [
        "aarch64-linux"
        "riscv64-linux"
      ];
    };

    backups = {
      enable = true;
      sshKeyPath = config.sops.secrets."borg/ssh_key".path;
    };
    persist = {
      enable = true;
      zfs = {
        enable = true;
        root = "rpool/enc/root";
      };
      dirs = [
        "/var/lib/sbctl" # lanzaboote pki bundle
        "/etc/secureboot"
      ];
      user = {
        enable = true;
        files = [
          ".claude.json"
        ];
        dirs = [
          ".claude"
          ".codex"
          ".xwechat"
          ".config/Code"
          ".config/aerc"
          ".config/chromium"
          ".config/doom"
          ".config/emacs"
          ".config/hamradio" # qlog
          ".config/opencode"
          ".config/net.imput.helium"
          ".config/PrusaSlicer"
          ".cache/rclone"
          ".local/share/WSJT-X"
          ".local/share/calendars"
          ".local/share/contacts"
          ".local/share/direnv"
          ".local/share/hamradio/QLog"
          ".local/share/keyrings"
          ".local/share/khal"
          ".local/share/vdirsyncer"
          ".local/share/zoxide"
          ".local/share/zsh"
          ".local/share/opencode"
          ".local/state/moshi"
          ".tqsl"
          ".vscode"
          ".zotero"
        ];
      };
    };
  };

  nix = {
    buildMachines = [
      {
        hostName = "oreamnos";
        systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];
        maxJobs = 64;
        speedFactor = 1;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
        mandatoryFeatures = [ ];
        sshUser = "humaid";
        # Just use borg ssh key
        sshKey = config.sops.secrets."borg/ssh_key".path;
      }
    ];

    distributedBuilds = true;
  };

  hardware.keyboard.zsa.enable = true;

  boot.kernelParams = [
    # Cap ZFS ARC at 4 GiB (was 8). On a 30 GiB interactive laptop running
    # browsers, postgres and qemu emulation, a smaller ARC leaves more baseline
    # headroom and reduces how often we reach for swap at all. ARC reclaim under
    # pressure is laggy, so a lower cap is worth the slightly smaller file cache.
    "zfs.zfs_arc_max=4294967296"

    # DIAGNOSTIC (2026-08-05, remove once resolved). anoa hard-resets with a fatal
    # Intel SoC crashlog in the ACPI BERT table and nothing in the journal. The
    # signature is bit-identical across Lenovo firmware 0.1.22 and 0.1.26, so it is
    # not a firmware bug we can update away; the fault sits in the SoC's power
    # management domain. Capping idle states is the one thing we can vary from here:
    # if uptime goes from ~40 min to hours, the fault is C-state related and this is
    # a usable stopgap until the board is serviced. Costs battery life, so drop this
    # line the moment the machine comes back from Lenovo.
    "intel_idle.max_cstate=1"
  ];
  boot.kernel.sysctl."kernel.sysrq" = lib.mkForce 1;

  # will do manually, too resource intensive.
  services.zfs.trim.enable = false;

  # Memory-pressure handling. anoa used to freeze under load (load avg >20, Sway
  # unresponsive, sometimes needing a hard reset). Root cause was memory thrash,
  # NOT the CPU scheduler: swap lived on a ZFS zvol, and swapping to a zvol under
  # pressure is a known OpenZFS deadlock (ZFS must allocate memory to service the
  # swap I/O). Processes pile up in D state, so load spikes from I/O stall rather
  # than CPU demand.
  #
  # Fix: zram (compressed RAM) becomes primary swap, the ZFS zvol is demoted to a
  # last-resort overflow, and systemd-oomd kills a runaway app before lockup.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };

  swapDevices = [
    {
      device = "/dev/zvol/rpool/enc/swap";
      # Below zram (100); only touched when zram is exhausted.
      priority = -2;
    }
  ];

  # zram is cheap, so lean on it instead of evicting page cache, and disable swap
  # read-ahead (pointless for RAM-backed swap).
  boot.kernel.sysctl = {
    "vm.swappiness" = 180;
    "vm.page-cluster" = 0;
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
  };

  # Kill the heaviest cgroup (e.g. a runaway browser tab in the user session)
  # before memory pressure stalls the whole machine. enableUserSlices is the key
  # bit: that's where the desktop apps live.
  #
  # That "heaviest cgroup" only became a meaningful unit of blame once
  # modules/desktop/uwsm.nix landed. Before it, greetd started sway directly, so
  # the compositor and every descendant shared one flat session-N.scope: oomd
  # had exactly one candidate worth picking and killing it dropped the desktop
  # to the greeter. It did so on 2026-08-27 and again on 2026-08-28.
  #
  # enableSystemSlice stays off deliberately. -.slice is monitored, and
  # systemd.resource-control(5) notes that a cgroup left at ManagedOOM*=auto is
  # still a kill *candidate* when an ancestor is set to kill, so nix-daemon and
  # friends under system.slice are already reachable. Arming system.slice as its
  # own trigger would only add a way to lose postgresql or tailscaled.
  systemd.oomd = {
    enable = true;
    enableUserSlices = true;
    enableRootSlice = true;
    settings.OOM = {
      DefaultMemoryPressureLimit = "50%";
      DefaultMemoryPressureDurationSec = "10s";

      # Act while zram still has room, before swap overflows onto the zvol and
      # hits the deadlock described above. Swap totals 39.4 GiB: 15.4 GiB zram
      # (39% of the total) plus the 24 GiB zvol, so any limit under 39% fires
      # before the zvol is touched at all. 30% is ~11.8 GiB, i.e. zram ~77%
      # full. The stock 90% is useless here -- 35 GiB of swap in use means the
      # zvol has been in play for a long time already.
      #
      # Note this limit is an AND: oomd acts only when the used fraction of RAM
      # *and* of swap both exceed it. RAM on this host sits above 30% almost
      # always, so swap usage is the effective trigger.
      SwapUsedLimit = "30%";
    };
  };

  # The two settings above do not apply on their own, which is why the machine
  # still froze on 2026-08-10 with oomd enabled:
  #
  #   * DefaultMemoryPressureLimit only covers units that set no limit of their
  #     own, and nixpkgs' oomd module puts ManagedOOMMemoryPressureLimit = 80%
  #     on every slice it manages. `oomctl` reported "Default Memory Pressure
  #     Limit: 50.00%" while every monitored cgroup listed 80%. It is mkDefault
  #     upstream, so a plain value here wins.
  #   * SwapUsedLimit only covers units with ManagedOOMSwap=kill, which nixpkgs
  #     never sets, so swap-based killing was entirely inactive -- "Swap
  #     Monitored CGroups:" in `oomctl` was empty.
  #
  # Verify after a rebuild with `oomctl`: each monitored cgroup should report a
  # 50% limit, and both / and /user.slice should appear under the swap section.
  # The user manager keeps a separate 80% drop-in of its own on app.slice and
  # friends (/etc/systemd/user/slice.d, applied to every user slice by type);
  # that is left alone as a later backstop, since the 50% on user.slice sits
  # above it and fires first.
  systemd.slices."-".sliceConfig = {
    ManagedOOMMemoryPressureLimit = "50%";
    ManagedOOMSwap = "kill";
  };
  systemd.slices."user".sliceConfig = {
    ManagedOOMMemoryPressureLimit = "50%";
    ManagedOOMSwap = "kill";
  };

  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/persist/var/lib/sbctl";
  };
  environment.systemPackages = with pkgs; [
    sbctl # for lanzaboote
    asdbctl # apple studio display
    intel-gpu-tools

    rpi-imager
  ];

  # Intel VAAPI hardware video decode (iHD/intel-media-driver) so browsers
  # and mpv offload video off the CPU, saving battery and heat.
  hardware.graphics.extraPackages = with pkgs; [ intel-media-driver ];
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = false;
  services.hardware.bolt.enable = true;

  services.postgresql = {
    enable = true;
    extensions =
      ps: with ps; [
        postgis
        pgvector
      ];
    ensureUsers = [
      {
        name = "humaid";
        ensureClauses = {
          superuser = true;
          login = true;
          createdb = true;
        };
      }
    ];
  };

  boot.initrd.kernelModules = [
    "udf" # dvds
  ];

  networking.firewall.allowedTCPPorts = [
    8081
  ];

  # mbzuai-cs-printer.huma.id is served from hisn and proxied back here over
  # the mesh. The host firewall already trusts sifr0 wholesale, so this is the
  # rule that actually gates it: nebula's own firewall defaults to inbound
  # icmp plus the `trusted` and `gadgets` groups, and drops everything else
  # before nginx on hisn gets a connection. Matches on the name in the peer's
  # certificate, so only hisn reaches this port — not every node on the mesh.
  # Definitions of this list merge, so this adds to the module's defaults
  # rather than replacing them.
  services.nebula.networks.sifr0.firewall.inbound = [
    {
      host = "hisn";
      port = "8585";
      proto = "tcp";
    }
  ];

  home-manager.users."${vars.user}" = {
    programs = {
      vdirsyncer.enable = true;
      khard.enable = true;
      khal = {
        enable = true;
        settings = {
          default = {
            default_calendar = "06D0D330-6A15-4B40-8D25-40180AD0340A";
          };
        };
      };
      aerc.enable = true;
      aerc.extraConfig = {
        general.unsafe-accounts-conf = true;
        compose.address-book-cmd = "khard email --parsable --remove-first-line --search-in-source-files %s";
        viewer.alternatives = "text/plain,text/html";
        filters = {
          "text/plain" = "colorize";
          "text/html" = "html | colorize";
        };
      };

    };
    services.vdirsyncer = {
      enable = true;
      frequency = "hourly";
    };

    accounts.email.accounts.mehumaid = {
      aerc.enable = true;
      primary = true;
      address = "me@huma.id";
      realName = "Humaid Alqasimi";
      userName = "me@huma.id";

      imap.host = "imap.migadu.com";
      imap.port = 993;
      imap.tls.enable = true;
      imap.authentication = "plain";

      smtp.host = "smtp.migadu.com";
      smtp.port = 465;
      smtp.tls.enable = true;
      smtp.authentication = "plain";

      passwordCommand = "${pkgs.coreutils}/bin/cat ${
        config.sops.secrets."migadu/mehumaid-password".path
      }";

      aerc.extraAccounts = {
        "source-cred-cmd" = "${pkgs.coreutils}/bin/cat ${
          config.sops.secrets."migadu/mehumaid-password".path
        }";
        "outgoing-cred-cmd" = "${pkgs.coreutils}/bin/cat ${
          config.sops.secrets."migadu/mehumaid-password".path
        }";
      };
    };

    accounts.contact = {
      basePath = ".local/share/contacts";

      accounts.alq = {
        remote = {
          type = "carddav";
          url = "https://dav.alq.ae/.well-known/carddav";
          userName = "humaid";
          passwordCommand = [
            "${pkgs.coreutils}/bin/cat"
            "${config.sops.secrets."dav/password".path}"
          ];
        };

        vdirsyncer.enable = true;
        vdirsyncer.collections = [ "80ef269f-cdde-4a2f-e5b8-dd5fff1ca608" ];

        khard = {
          enable = true;
          type = "discover";
          glob = "*";
        };
      };

    };

    accounts.calendar = {
      basePath = ".local/share/calendars";

      accounts = {
        alq = {
          remote = {
            type = "caldav";
            url = "https://dav.alq.ae/.well-known/caldav";
            userName = "humaid";
            passwordCommand = [
              "${pkgs.coreutils}/bin/cat"
              "${config.sops.secrets."dav/password".path}"
            ];
          };

          vdirsyncer.enable = true;
          vdirsyncer.collections = [ "06D0D330-6A15-4B40-8D25-40180AD0340A" ];

          khal = {
            enable = true;
            type = "discover";
            glob = "*";
            addresses = [ "me@huma.id" ];
          };
        };
        uni = {
          remote.type = "http";
          vdirsyncer = {
            enable = true;
            urlCommand = [
              "cat"
              "${config.sops.secrets.mbzuai-calendar.path}"
            ];
          };

          khal = {
            enable = true;
            readOnly = true;
          };
        };
      };
    };

    # kanshi parses ~/.config/kanshi/config once, at startup, and home-manager's
    # unit carries no trigger on that file -- so a switch that only edits the
    # profile list leaves the running kanshi on the config it was launched with
    # until the next login.  That is the other half of why the rescale below
    # looked intermittent: any session predating a change to these profiles
    # silently ran the old exec list, or none at all.  Fold the settings into
    # the unit so sd-switch sees the unit change and restarts kanshi.  Hashed
    # because X-Restart-Triggers is a single unit-file line.
    systemd.user.services.kanshi.Unit.X-Restart-Triggers = [
      (builtins.hashString "sha256" (
        builtins.toJSON config.home-manager.users.${vars.user}.services.kanshi.settings
      ))
    ];

    services.kanshi = {
      inherit (config.sifr.desktop.sway) enable;

      settings = [
        {
          profile = {
            name = "internal";
            outputs = [
              {
                criteria = "Samsung Display Corp. 0x419F Unknown";
                status = "enable";
              }
            ];
            exec = [ rescaleEmacsFrames ];
          };
        }
        {
          profile = {
            name = "desk";
            # Both Studio Display ports share the identical description
            # "Apple Computer Inc StudioDisplay 0x6EBF361E", so kanshi can only
            # tell DP-1 (the real 5K panel) from DP-2 by connector name. Match
            # every output by connector here, otherwise no profile matches and
            # the internal panel stays on.
            outputs = [
              {
                criteria = "eDP-1";
                status = "disable";
              }
              {
                criteria = "DP-1";
                status = "enable";
                mode = "5120x2880";
                scale = 2.0;
                position = "0,0";
              }
              {
                criteria = "DP-2";
                status = "disable";
              }
            ];
            exec = [
              ''${pkgs.sway}/bin/swaymsg "workspace 1, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 2, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 3, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 4, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 5, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 6, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 7, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 8, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 9, move workspace to output DP-1"''
              ''${pkgs.sway}/bin/swaymsg "workspace 10, move workspace to output DP-1"''
              rescaleEmacsFrames
            ];
          };
        }
        {
          profile = {
            name = "desk-mbzuai-a-7-11";
            outputs = [
              {
                criteria = "Samsung Display Corp. 0x419F Unknown";
                status = "disable";
              }
              {
                criteria = "Dell Inc. DELL P2725H 25FCXZ3";
                status = "enable";
                mode = "1920x1080";
              }
            ];
            exec = [ rescaleEmacsFrames ];
          };
        }
        {
          profile = {
            name = "dell-p2722h-external-only";
            outputs = [
              {
                criteria = "Samsung Display Corp. 0x419F Unknown";
                status = "disable";
              }
              {
                criteria = "Dell Inc. DELL P2722H 5ZR83P3";
                status = "enable";
                mode = "1920x1080@60Hz";
                position = "0,0";
              }
            ];
            exec = [ rescaleEmacsFrames ];
          };
        }
        {
          profile = {
            name = "samsung-1080p-side-by-side";
            # 1080p Samsung external.  Its EDID carries no real model or serial
            # ("SAMSUNG" / 0x00000001), so this criteria would also match any
            # other Samsung panel that lies the same way -- acceptable here,
            # nothing else on this machine reports that pair.  Laid out exactly
            # as it was arranged by hand: external on the left at the origin,
            # internal to its right, top edges aligned.  Both at scale 2, so
            # the external is 960x540 logical and the internal 1440x900, and
            # the internal starts at x=960 where the external ends.
            outputs = [
              {
                criteria = "Samsung Electric Company SAMSUNG 0x00000001";
                status = "enable";
                mode = "1920x1080@60Hz";
                scale = 2.0;
                position = "0,0";
              }
              {
                criteria = "Samsung Display Corp. 0x419F Unknown";
                status = "enable";
                mode = "2880x1800@120Hz";
                scale = 2.0;
                position = "960,0";
              }
            ];
            exec = [ rescaleEmacsFrames ];
          };
        }
        {
          profile = {
            name = "tii-crc-desk";
            outputs = [
              {
                criteria = "Dell Inc. DELL U3423WE DYQKMP3";
                status = "enable";
                mode = "3440x1440@60Hz";
                scale = 2.0;
                position = "0,0";
              }
              {
                criteria = "Samsung Display Corp. 0x419F Unknown";
                status = "enable";
                mode = "2880x1800@120Hz";
                scale = 2.0;
                position = "140,720";
              }
            ];
            exec = [ rescaleEmacsFrames ];
          };
        }
      ];
    };
  };

  system.stateVersion = "25.04";
}
