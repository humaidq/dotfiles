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

  sops.secrets.kavita-token = {};
  services.kavita = {
    enable = true;
    tokenKeyFile = config.sops.secrets.kavita-token.path;
  };

  services.mealie = {
    enable = true;
  };
  services.audiobookshelf.enable = true;
  services.jellyseerr.enable = true;
  services.searx = {
    enable = true;
    settings = {
      server.port = "3342";
    };
  };

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
    virtualHosts."http://books.alq".extraConfig = ''
      reverse_proxy :5000
    '';
    virtualHosts."http://audiobooks.alq".extraConfig = ''
      reverse_proxy :8000
    '';
    virtualHosts."http://tv.alq".extraConfig = ''
      reverse_proxy http://nas:8096
    '';
    virtualHosts."http://recipes.alq".extraConfig = ''
      reverse_proxy :9000
    '';
    virtualHosts."http://search.alq".extraConfig = ''
      reverse_proxy :3342
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
        "Entertainment" = [
          {
            "TV" = {
              description = "Movie Streaming (Jellyfish)";
              href = "http://tv.alq/";
              siteMonitor = "http://nas:8096";
              icon = "mdi-youtube-tv";
            };
          }
          {
            "Catalogue" = {
              description = "Movie Search Catalogue";
              href = "http://catalogue.alq/";
              siteMonitor = "http://catalogue.alq/";
              icon = "mdi-movie-search";
            };
          }
        ];
      }
      {
        "Resources" = [
          {
            "Recipes" = {
              description = "Recipe Book (Mealie)";
              href = "http://recipes.alq/";
              siteMonitor = "http://recipes.alq/";
              icon = "mdi-silverware-fork-knife";
            };
          }
          {
            "Books" = {
              description = "eBooks Library";
              href = "http://books.alq/";
              siteMonitor = "http://books.alq/";
              icon = "mdi-bookshelf";
            };
          }
          {
            "Audio Books" = {
              description = "Audio Books Library";
              href = "http://audiobooks.alq/";
              siteMonitor = "http://audiobooks.alq/";
              icon = "mdi-book-music";
            };
          }
        ];
      }
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
          {
            "Etisalat" = {
              description = "Etisalat Router";
              href = "http://192.168.1.1/";
              siteMonitor = "http://192.168.1.1/";
              icon = "mdi-router-network";
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
        ratelimit = 0; # no limit
        cache_size = 10000000; # 10mb
        cache_ttl_min = 2400; # 40 min
        cache_ttl_max = 86400; # 24 hr
        cache_optimistic = true;
        upstream_dns = [
          "213.42.20.20"
          "195.229.241.222"
          "1.1.1.1"
          "8.8.8.8"
        ];
        fallback_dns = [
          "1.1.1.1"
          "8.8.8.8"
        ];
        bootstrap_dns = [
          "1.1.1.1"
          "8.8.8.8"
        ];
        upstream_mode = "parallel";
      };
      user_rules = [
        "@@||.wiki^"
      ];
      filtering = {
        blocked_response_ttl = 2400;
        blocking_mode = "null_ip";
      };
      filtering.rewrites = [
        {
          domain = "adguard.alq";
          answer = "${config.networking.hostName}.alq";
        }
        {
          domain = "home.alq";
          answer = "${config.networking.hostName}.alq";
        }
        {
          domain = "lldap.alq";
          answer = "${config.networking.hostName}.alq";
        }
        {
          domain = "catalogue.alq";
          answer = "${config.networking.hostName}.alq";
        }
        {
          domain = "books.alq";
          answer = "${config.networking.hostName}.alq";
        }
        {
          domain = "recipes.alq";
          answer = "${config.networking.hostName}.alq";
        }
        {
          domain = "audiobooks.alq";
          answer = "${config.networking.hostName}.alq";
        }
        {
          domain = "tv.alq";
          answer = "nas.alq";
        }
      ];
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
          name = "OISD (NSFW)";
          url = "https://nsfw.oisd.nl";
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
          enabled = false;
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
