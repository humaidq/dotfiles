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

  services.lldap = {
    enable = true;
    environmentFile = "${config.sops.secrets.lldap-env.path}";
    settings = {
      ldap_base_dn = "dc=home,dc=alq";
      ldap_user_email = "admin@home.alq";
      http_url = "http://lldap.alq";
    };
  };

  services.jellyseerr.enable = true;

  services.caddy = {
    enable = true;
    virtualHosts."http://home.alq".extraConfig = ''
      reverse_proxy :8082
    '';
    virtualHosts."http://lldap.alq".extraConfig = ''
      reverse_proxy :17170
    '';
    virtualHosts."http://adguard.alq".extraConfig = ''
      reverse_proxy :3000
    '';
    virtualHosts."http://catalogue.alq".extraConfig = ''
      reverse_proxy :${builtins.toString config.services.jellyseerr.port}
    '';
    virtualHosts."http://tv.alq".extraConfig = ''
      reverse_proxy http://nas:8096
    '';
  };

  services.homepage-dashboard = {
    enable = true;
    listenPort = 8082;
    settings = {
      title = "home.alq";
      startURL = "http://home.alq";
      background = "https://images.unsplash.com/photo-1502790671504-542ad42d5189?auto=format&fit=crop&w=2560&q=80";
    };
    widgets = [
      {
        search = {
          provider = "duckduckgo";
          target = "_blank";
          showSearchSuggestions = true;
        };
      }
      {
        openmeteo = {
          latitude = "25.4018";
          longitude = "55.4788";
          timezone = "Asia/Dubai";
          units = "metric";
          cache = 15;
        };
      }
    ];
    services = [
      {
        "Services" = [
          {
            "NAS" = {
              description = "Network Attached Storage (Synology)";
              href = "http://nas.alq/";
              siteMonitor = "http://nas.alq/";
              icon = "mdi-nas";
            };
          }
          {
            "TV" = {
              description = "Home Movie Streaming (Jellyfish)";
              href = "http://tv.alq/";
              siteMonitor = "http://nas:8096";
              icon = "mdi-youtube-tv";
            };
          }
          {
            "Gertruda" = {
              description = "Prusa MK3S+ 3D Printer";
              href = "http://gertruda.alq/";
              siteMonitor = "http://gertruda.alq/";
              icon = "mdi-printer-3d-nozzle";
            };
          }
        ];
      }
      {
        "Administration" = [
          {
            "AdGuard" = {
              description = "Network DNS & DHCP server (AdGuard Home)";
              href = "http://adguard.alq/";
              siteMonitor = "http://adguard.alq/";
              icon = "mdi-security";
            };
          }
        ];
      }
    ];
  };

  services.adguardhome = {
    enable = true;
    openFirewall = true;
    settings = {
      host = "0.0.0.0";
      dns = {
        port = 53;
        ratelimit = 0;
        upstream_dns = [
          "tls://1dot1dot1dot1.cloudflare-dns.com"
          "tls://dns.google"
        ];
        fallback_dns = [
          "https://dns.cloudflare.com/dns-query"
          "https://dns.google/dns-query"
        ];
        bootstrap_dns = [
          "1.1.1.1"
          "8.8.8.8"
        ];
        upstream_mode = "parallel";
      };
      dhcp = {
        enabled = true;
        interface_name = "end0";
        dhcpv4 = {
          gateway_ip = "192.168.1.1";
          subnet_mask = "255.255.255.0";
          range_start = "192.168.1.10";
          range_end = "192.168.1.200";
        };
        local_domain_name = "alq";
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
          enabled = true;
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
        {
          name = "uBlock Badware Risks";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt";
          enabled = true;
        }
        {
          name = "Dandelion Sprout's Anti-Malware List";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_12.txt";
          enabled = true;
        }
        {
          name = "Phishing URL Blocklist (PhishTank and OpenPhish)";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_30.txt";
          enabled = true;
        }
        {
          name = "Developer Dan Ads and Tracking";
          url = "https://www.github.developerdan.com/hosts/lists/ads-and-tracking-extended.txt";
          enabled = true;
        }
        {
          name = "Developer Dan Hate and Junk";
          url = "https://www.github.developerdan.com/hosts/lists/hate-and-junk-extended.txt";
          enabled = true;
        }
        {
          name = "Hagezi Normal";
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/multi.txt";
          enabled = false;
        }
        {
          name = "Hagezi Pro";
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt";
          enabled = true;
        }
        {
          name = "Hagezi Threat Intelligence Feeds";
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.txt";
          enabled = true;
        }
        {
          name = "Hagezi Pop-up Ads";
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/popupads.txt";
          enabled = true;
        }
        {
          name = "Hagezi Fake";
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/fake.txt";
          enabled = true;
        }
        {
          name = "Hagezi Abused TLDs";
          url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/spam-tlds.txt";
          enabled = true;
        }
        {
          name = "OSINT Digitalside.it Threat-Intel";
          url = "https://osint.digitalside.it/Threat-Intel/lists/latestdomains.txt";
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
