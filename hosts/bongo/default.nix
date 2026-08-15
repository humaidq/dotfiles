{
  self,
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS.base
    self.nixosModules.sifrOS.personal.base
    self.nixosModules.sifrOS.security
    self.nixosModules.sifrOS.router
    self.nixosModules.sifrOS.persist
    self.nixosModules.sifrOS.server
    inputs.disko.nixosModules.disko
    #inputs.lanzaboote.nixosModules.lanzaboote
    (import ./hardware.nix)
    (import ./disk.nix)
  ];
  networking.hostName = "bongo";
  networking.enableIPv6 = false;

  services.openssh = {
    enable = true;
    openFirewall = false;
  };

  sops.secrets."nebula/crt" = {
    sopsFile = ../../secrets/bongo.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."nebula/key" = {
    sopsFile = ../../secrets/bongo.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };

  sops.secrets."etisalat/pppd-config" = {
    sopsFile = ../../secrets/bongo.yaml;
  };

  # Ungated, unlike the dnsmasq secret below: nothing about the low-trust pool
  # depends on dnsmasq, so it stays declared in the client specialisation too
  # and cannot become the dead manifest entry that note warns about.
  sops.secrets."router/lowtrust-macs" = {
    sopsFile = ../../secrets/bongo.yaml;
    mode = "0400";
    restartUnits = [ "nft-lowtrust-macs.service" ];
  };

  # Gated on dnsmasq itself: the client specialisation turns dnsmasq off, and
  # the NixOS module only declares the dnsmasq user when it is enabled. A
  # secret owned by a user that does not exist fails manifest validation, and
  # sops-install-secrets validates the whole manifest before it decrypts
  # anything — so one dead entry leaves /run/secrets empty and takes nebula,
  # and with it SSH over the mesh, down alongside it.
  sops.secrets."dnsmasq/dhcp-hosts" = lib.mkIf config.services.dnsmasq.enable {
    sopsFile = ../../secrets/bongo.yaml;
    owner = "dnsmasq";
    group = "dnsmasq";
    mode = "0440";
    reloadUnits = [ "dnsmasq.service" ];
  };

  users.users.${config.sifr.username}.extraGroups = [ "dnsmasq" ];

  # Packet captures are a routine debugging step here, so don't prompt for a
  # password. Both paths are listed since sudo matches whatever PATH resolved.
  #
  # nft is here for the same reason one step later: once something unwanted is
  # identified, the useful next move is a drop rule that takes effect now
  # rather than at the next deploy. Rules added that way belong in their own
  # table so a rebuild flushes them; anything worth keeping goes in
  # custom-ip-blocklist.txt instead.
  #
  # Note this is effectively root: nft can rewrite the whole ruleset, including
  # the blocklists. It is granted because the alternative is entering a
  # password on a machine whose whole job is to be unattended, not because the
  # command is safe in isolation.
  security.sudo-rs.extraRules = [
    {
      users = [ config.sifr.username ];
      commands = [
        {
          command = "/run/current-system/sw/bin/tcpdump";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${pkgs.tcpdump}/bin/tcpdump";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/nft";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${pkgs.nftables}/bin/nft";
          options = [ "NOPASSWD" ];
        }
        # conntrack reads the live flow table with byte counters, which answers
        # "what is carrying this device's traffic right now" in one call rather
        # than the two minutes a capture costs. Read-only in practice for this
        # use, though -D can delete entries, so it sits in the same
        # effectively-root bracket as the two above.
        {
          command = "/run/current-system/sw/bin/conntrack";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${pkgs.conntrack-tools}/bin/conntrack";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  sifr = {
    autoupgrade.enable = true;
    basePlus.enable = true;
    personal = {
      net = {
        sifr0 = true;
        cacheOverPublic = true;
        firewallInterfaces = [ config.sifr.router.lan0 ];
        node-crt = config.sops.secrets."nebula/crt".path;
        node-key = config.sops.secrets."nebula/key".path;
      };
      o11y.client.enable = true;
    };

    router = {
      enable = true;
      meshAddress = "10.10.0.16"; # bongo
      localDomain = "v6.alq.ae";
      customDNSMappings = {
        "alq.ae" = "10.10.0.12,10.20.0.250";
        "cache.huma.id" = "10.10.0.12,10.20.0.250";
        "g.huma.id" = "10.10.0.12,10.20.0.250";
      };
      pppdConfig = config.sops.secrets."etisalat/pppd-config".path;
      uplink = {
        enable = true;
        # Measured on this line at 4.7-6.9 ms with 0.4 ms deviation and no
        # loss, which is what an in-country anycast node looks like: neither
        # resolver leaves the ISP's network, so both are core anchors whatever
        # their operator's headquarters is. Two rather than one so that a
        # single sick anycast node reads as one anchor degrading rather than as
        # the uplink failing.
        anchors = [
          {
            name = "cloudflare";
            address = "1.1.1.1";
            role = "core";
            # Paired with a Voice-marked twin. One anchor is enough for the
            # differential — it asks whether the queue that is building is on
            # this side of the line or the far side, and that answer does not
            # differ per anchor. The steadiest core anchor makes the cleanest
            # comparison.
            pairVoice = true;
          }
          {
            name = "google";
            address = "8.8.8.8";
            role = "core";
          }
          # THREE TRANSIT PATHS, CHOSEN FOR PHYSICAL DIVERSITY rather than for
          # covering continents. From here there are essentially two distinct
          # submarine routes, and they fail independently:
          #
          #   * westward, through the Red Sea corridor to Europe. This is the
          #     one that breaks; the 2024 cable cuts took out a large share of
          #     UAE-Europe capacity at once.
          #   * eastward, to India and south-east Asia.
          #
          # Frankfurt degraded while Bangalore stays flat localises a fault to the
          # westward path, which is a different conversation with the ISP than
          # "everything is slow". Anchors in Africa or South America were
          # considered and left out: no traffic from this house goes there, so
          # a degradation on one would be unactionable, and an anchor that
          # cannot change a decision is a row diluting the page.
          #
          # Vultr's per-region ping hosts. Published for latency testing and
          # unicast per region, which is the property that matters — an anycast
          # address would be answered by a nearer node and silently become
          # another core anchor. The addresses are pinned rather than resolved
          # because a name that later moves would change what is measured
          # without changing this file; the cost is that a renumbering by the
          # provider shows up as a step change in the baseline rather than as
          # an error, so these are worth re-resolving occasionally.
          {
            name = "frankfurt";
            address = "108.61.210.117"; # fra-de-ping.vultr.com
            role = "transit";
          }
          {
            name = "bangalore";
            address = "139.84.130.100"; # blr-in-ping.vultr.com
            role = "transit";
          }
          {
            name = "newjersey";
            address = "108.61.149.182"; # nj-us-ping.vultr.com
            role = "transit";
          }
          # Kept alongside the three above for the one property none of them
          # has: it can be logged into. When an anchor degrades the first
          # question is whether the far host is simply having a bad day, and
          # this is the only target where that can be answered rather than
          # assumed.
          #
          # The endpoint is already in the tree at
          # modules/personal/networking/nebula.nix, and this probes the public
          # address directly over the WAN rather than the mesh address, so what
          # is measured is the internet path and not the tunnel.
          {
            name = "lighthouse";
            address = "139.84.173.48";
            role = "transit";
          }
        ];
      };
      # No shaped tier here: imo is dropped outright at every hour, and has
      # been long enough that the throttle compromise bingo runs is not worth
      # carrying at this site.
      imoPolicy = "block";
      # Same gate as the secret above, so this does not reference a secret
      # that the client specialisation no longer declares.
      dhcp.hostsFile =
        lib.mkIf config.services.dnsmasq.enable
          config.sops.secrets."dnsmasq/dhcp-hosts".path;
      qos.lowPriorityPorts = [
        6881
        51413
      ];
      qos.highPriorityPorts = [
        53
        853
      ];
      # Same policy as bingo, and the lists behind it are shared: the ports,
      # subnets, ASNs and STUN hosts all live in modules/router and apply
      # wherever the pool is enabled. Only membership is per-site, because only
      # the MAC list is a secret and each router decrypts its own.
      #
      # Note what this pulls in beyond the drops: pool devices here also lose
      # the Voice tin, which on this host is a sharper change than on bingo —
      # imoPolicy is "block" rather than "throttle", so a device already denied
      # imo outright now also gets no priority for whatever it calls with
      # instead.
      lowTrust = {
        enable = true;
        macFile = config.sops.secrets."router/lowtrust-macs".path;
      };
      suricata.enable = false;
    };

    persist = {
      enable = true;
      btrfs.enable = true;
      dirs = [
        "/var/lib/nft-blocklists"
      ];
    };
  };

  services.nebula.networks.sifr0.firewall = {
    inbound = [
      {
        host = "any";
        port = "53";
        proto = "udp";
      }
      {
        host = "any";
        port = "53";
        proto = "tcp";
      }
    ];
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "25.11";
}
