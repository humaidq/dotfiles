{
  pkgs,
  lib,
  vars,
  config,
  ...
}: {
  sifr = {
    security.harden = false;
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
    };
		profiles.base = true;
    profiles.basePlus = true;
  };

  #boot.kernelPackages = pkgs.linuxPackages_rpi4;
  hardware.enableRedistributableFirmware = true;
  networking.networkmanager.enable = false;

	services.adguardhome = {
		enable = true;
    openFirewall = true;
    settings = {
      port = "3001";
      host = "0.0.0.0";
      dns = {
        port = "53";
        ratelimit = "60";
        upstream_dns = [
          "https://dns.cloudflare.com/dns-query"
          "https://dns.google/dns-query"
        ];
        fallback_dns = [
          "tls://1dot1dot1dot1.cloudflare-dns.com"
          "tls://dns.google"
        ];
        bootstrap_dns = [
          "1.1.1.1"
          "8.8.8.8"
        ];
        upstream_mode = "parallel";
      };
      filters = [
        {
          name = "AdGuard DNS filter";
          url = "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt";
          enabled = true;
        }
        {
          name = "AdAway Default Blocklist";
          url = "https://adaway.org/hosts.txt";
          enabled = true;
        }
        {
          name = "StevenBack Hosts Big Three";
          url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn/hosts";
          enable = true;
        }
        {
          name = "OISD (Big)";
          url = "https://big.oisd.nl";
          enabled = true;
        }
        {
          name = "Phishing Army";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_18.txt";
          enabled = true;
        }
      ];
    };
	};

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  networking.wireless = {
    enable = true;
    environmentFile = config.sops.secrets.wifi-2g.path;
    networks = {
      "@ssid@" = {
        psk = "@pass@";
      };
    };
  };

  boot.initrd.kernelModules = ["sun4i-drm"];
  boot.kernelPackages = pkgs.linuxPackages_latest;

  services.openssh.enable = true;
  networking.firewall.enable = false;

  documentation.enable = lib.mkForce false;
  documentation.nixos.enable = lib.mkForce false;
  security.polkit.enable = lib.mkForce false;
  security.rtkit.enable = lib.mkForce false;
  security.apparmor.enable = lib.mkForce false;

  users.users.${vars.user} = {
    isNormalUser = true;
    hashedPassword = "$6$67sQfb8Pm3Jyvdvo$OPXnLbgHCdoRfhlhhz/pygvJ32ZA.L0HifV.fBSVW47SsfKK6xiroi/Xx.hcB6YJ94XXaiUH5zqDvnAmKq6gE1";
  };
}
