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
      localDomain = "v6.alq.ae";
      customDNSMappings = {
        "alq.ae" = "10.10.0.12,10.20.0.250";
        "cache.huma.id" = "10.10.0.12,10.20.0.250";
        "g.huma.id" = "10.10.0.12,10.20.0.250";
      };
      pppdConfig = config.sops.secrets."etisalat/pppd-config".path;
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
