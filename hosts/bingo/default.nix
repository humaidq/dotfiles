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
  networking.hostName = "bingo";
  networking.enableIPv6 = true;

  services.openssh = {
    enable = true;
    openFirewall = false;
  };

  sops.secrets."nebula/crt" = {
    sopsFile = ../../secrets/bingo.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."nebula/key" = {
    sopsFile = ../../secrets/bingo.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };

  sops.secrets."etisalat/pppd-config" = {
    sopsFile = ../../secrets/bingo.yaml;
  };

  # Management login for the fibre terminal upstream of the WAN port. Same
  # reasoning as on bongo: the username is a secret too, because the account is
  # a root shell on the operator's equipment and this repository is public.
  # This site's ONT is a different unit — a different serial and a newer
  # Dropbear — but the operator provisions the same credentials on both.
  sops.secrets."ont/username" = {
    sopsFile = ../../secrets/bingo.yaml;
    mode = "0400";
    restartUnits = [ "ont-textfile.service" ];
  };
  sops.secrets."ont/password" = {
    sopsFile = ../../secrets/bingo.yaml;
    mode = "0400";
    restartUnits = [ "ont-textfile.service" ];
  };

  # MaxMind licence key for the GeoLite2 country database, so the peers page
  # can report where a peer is rather than where its network is registered.
  # In all.yaml because both routers fetch the same database with the same key.
  sops.secrets."maxmind/license-key" = {
    sopsFile = ../../secrets/all.yaml;
    mode = "0400";
    restartUnits = [ "geoip-update.service" ];
  };

  sifr.router.geoip = {
    enable = true;
    accountId = "1394850";
    licenseKeyFile = config.sops.secrets."maxmind/license-key".path;
  };

  sops.secrets."router/lowtrust-macs" = {
    sopsFile = ../../secrets/bingo.yaml;
    mode = "0400";
    restartUnits = [ "nft-lowtrust-macs.service" ];
  };

  # The access point list the status page renders, `name,address,username,password`
  # per line. It now carries the APs' admin logins for the reboot button, so it
  # is group-readable at 0440 rather than world-readable: router-web joins the
  # router-ap group (see modules/router/web.nix) to read it, and nothing else on
  # the router can. router-web runs under DynamicUser, so the group is how it is
  # granted access with no uid to name at build time.
  sops.secrets."router/access-points" = {
    sopsFile = ../../secrets/bingo.yaml;
    group = "router-ap";
    mode = "0440";
    restartUnits = [ "router-web.service" ];
  };

  # Gated on dnsmasq itself: the client specialisation turns dnsmasq off, and
  # the NixOS module only declares the dnsmasq user when it is enabled. A
  # secret owned by a user that does not exist fails manifest validation, and
  # sops-install-secrets validates the whole manifest before it decrypts
  # anything — so one dead entry leaves /run/secrets empty and takes nebula,
  # and with it SSH over the mesh, down alongside it.
  sops.secrets."dnsmasq/dhcp-hosts" = lib.mkIf config.services.dnsmasq.enable {
    sopsFile = ../../secrets/bingo.yaml;
    owner = "dnsmasq";
    group = "dnsmasq";
    mode = "0440";
    reloadUnits = [ "dnsmasq.service" ];
  };

  users.users.${config.sifr.username}.extraGroups = [ "dnsmasq" ];

  # Both spellings, as on oreamnos: which implementation is in use depends on
  # which module is enabled, and setting only one leaves the other prompting.
  #
  # This is a router that is administered over the mesh and never sat in front
  # of. A remote rebuild has to answer a sudo prompt that nothing non-interactive
  # can answer, which is the case this exists for — and the specific grants
  # below already amount to root, so the honest reading is that this widens the
  # path rather than the privilege.
  security.sudo-rs.wheelNeedsPassword = false;
  security.sudo.wheelNeedsPassword = false;

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
      ssh.acceptDevKeys = true;
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
      meshAddress = "10.10.0.18"; # bingo
      localDomain = "v10.alq.ae";
      # A /24 rather than bongo's /16: this site has far fewer clients, and the
      # smaller pool keeps the reverse zone (50.168.192.in-addr.arpa) scoped to
      # what this router actually owns.
      lanAddress = "192.168.50.1/24";
      pppdConfig = config.sops.secrets."etisalat/pppd-config".path;
      # As on bongo, and for the same reason the anchor set is shared: an
      # optical reading that degrades at one site and not the other is that
      # site's own fibre, which is the one uplink question the anchors below
      # cannot answer at all.
      ont = {
        enable = true;
        usernameFile = config.sops.secrets."ont/username".path;
        passwordFile = config.sops.secrets."ont/password".path;
      };
      # Same anchor set as bongo, which is the point: two sites on the same ISP
      # probing identical targets means a degradation seen at one and not the
      # other is local to that site, and one seen at both is the ISP. See the
      # comments on bongo for what each role is evidence about.
      uplink = {
        enable = true;
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
          # Westward, eastward and the US, per the rationale on bongo. The two
          # sites must probe the same addresses or the cross-site comparison
          # this whole set exists for stops working, so these are copied rather
          # than chosen again.
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
          # hisn was here and is gone, for the reason spelled out on bongo:
          # the path to it depends on which Etisalat pool the 05:00 redial
          # happens to draw, so it measures the lottery rather than the line.
          # Removed from both sites together — the anchor sets are identical on
          # purpose, and an anchor present at one site only cannot answer the
          # cross-site question this list exists for.
        ];
      };
      # Dropped outright on odd days of the month, shaped on even ones. Unlike
      # bongo this site is not willing to refuse imo every day, and a permanent
      # throttle does not hold either: once a call has gone peer to peer the
      # packets never touch a listed address, so the shaped tier only ever bites
      # call setup and the relayed leg.
      imoPolicy = "alternate";
      dhcp = {
        rangeStart = "192.168.50.100";
        rangeEnd = "192.168.50.250";
        routerAddress = "192.168.50.1";
        dnsServer = "192.168.50.1";
        # Same gate as the secret above, so this does not reference a secret
        # that the client specialisation no longer declares.
        hostsFile = lib.mkIf config.services.dnsmasq.enable config.sops.secrets."dnsmasq/dhcp-hosts".path;
      };
      qos.lowPriorityPorts = [
        6881
        51413
      ];
      qos.highPriorityPorts = [
        53
        853
      ];
      suricata.enable = false;
      accessPoints.file = config.sops.secrets."router/access-points".path;
      lowTrust = {
        enable = true;
        macFile = config.sops.secrets."router/lowtrust-macs".path;
        # Shapes pool traffic to CDN space past 50 MB, refilling at 20 MB/hour.
        # The one instrument that reaches domain fronting, where the edge is
        # shared with the whole house and the cover name is never resolved.
        cdnQuota.enable = true;
      };
      fullReboot.enable = true;
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
