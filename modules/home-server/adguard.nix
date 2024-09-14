{ config, lib, ... }:
let
  cfg = config.sifr.home-server;
  tsIP = "100.83.164.46";
  domainTS = sub: {
    domain = "${sub}.alq.ae";
    answer = tsIP;
  };
in
{
  config = lib.mkIf cfg.enable {
    topology.self.services.adguardhome.info = "https://adguard.alq.ae";
    services.resolved.enable = lib.mkForce false;
    networking.resolvconf.useLocalResolver = true;
    services.adguardhome = {
      enable = true;
      openFirewall = true;
      port = 3333;
      settings = {
        host = "0.0.0.0";
        dns = {
          port = 53;
          ratelimit = 0; # no limit
          cache_size = 10000000; # 10mb
          cache_ttl_min = 2400; # 40 min
          cache_ttl_max = 86400; # 24 hr
          cache_optimistic = true;
          anonymize_client_ip = false;

          safe_search = {
            enabled = true;
            google = true;
            duckduckgo = true;
            bing = true;
            youtube = false;
          };
          upstream_dns = [
            # Etisalat
            "213.42.20.20"
            "195.229.241.222"
            # Public
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
          "@@||rargb.to^"
          "@@||tracker.coppersurfer.tk^"
        ];
        filtering = {
          blocked_response_ttl = 2400;
          blocking_mode = "null_ip";
        };
        filtering.rewrites =
          map domainTS [
            "adguard"
            "deluge"
            "hydra"
            "radarr"
            "sonarr"
            "prowlarr"
            "vault"
            "ai"
            "ollama"
            "lldap"
            "catalogue"
            "books"
            "recipes"
            "audiobooks"
            "tv"
            "sso"
          ]
          ++ [
            {
              domain = "alq.ae";
              answer = "${tsIP}";
            }
          ];
        dhcp = {
          enabled = false;
          interface_name = "end0";
          dhcpv4 = {
            gateway_ip = "192.168.1.1";
            subnet_mask = "255.255.255.0";
            range_start = "192.168.1.10";
            range_end = "192.168.1.200";
          };
          local_domain_name = "alq.ae";
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
          {
            name = "ShadowWhisperer's Ads";
            url = "https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Ads";
            enabled = true;
          }
          {
            name = "ShadowWhisperer's Marketing";
            url = "https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Marketing";
            enabled = true;
          }
          {
            name = "ShadowWhisperer's Shock";
            url = "https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Shock";
            enabled = true;
          }
          {
            name = "ShadowWhisperer's Typo";
            url = "https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Typo";
            enabled = true;
          }
        ];
      };
    };
  };
}
