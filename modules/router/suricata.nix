{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.router;
  suricataCfg = cfg.suricata;
  queueNum = toString suricataCfg.queue;
  pppdService = "pppd-etisalat.service";
  renderedSettings = lib.filterAttrsRecursive (
    _: value: value != null
  ) config.services.suricata.settings;
in
{
  options.sifr.router.suricata = {
    enable = lib.mkEnableOption "Suricata IPS on the router";

    homeNet = lib.mkOption {
      type = lib.types.str;
      default = "[192.168.1.0/24]";
      description = "Address group used for Suricata HOME_NET.";
    };

    queue = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "NFQUEUE number used for inline inspection.";
    };
  };

  config = lib.mkIf (cfg.enable && suricataCfg.enable) {
    services.suricata = {
      enable = true;
      configFile = pkgs.writeText "suricata.yaml" ''
        %YAML 1.1
        ---
        ${lib.generators.toYAML { } renderedSettings}
      '';
      enabledSources = [ "et/open" ];
      settings = {
        vars = {
          address-groups = {
            HOME_NET = suricataCfg.homeNet;
            EXTERNAL_NET = "!$HOME_NET";
            HTTP_SERVERS = "$HOME_NET";
            SMTP_SERVERS = "$HOME_NET";
            SQL_SERVERS = "$HOME_NET";
            DNS_SERVERS = "$HOME_NET";
            TELNET_SERVERS = "$HOME_NET";
            AIM_SERVERS = "$EXTERNAL_NET";
            DC_SERVERS = "$HOME_NET";
            DNP3_SERVER = "$HOME_NET";
            DNP3_CLIENT = "$HOME_NET";
            MODBUS_CLIENT = "$HOME_NET";
            MODBUS_SERVER = "$HOME_NET";
            ENIP_CLIENT = "$HOME_NET";
            ENIP_SERVER = "$HOME_NET";
          };
          port-groups = {
            HTTP_PORTS = "80";
            SHELLCODE_PORTS = "!80";
            ORACLE_PORTS = "1521";
            SSH_PORTS = "22";
            DNP3_PORTS = "20000";
            MODBUS_PORTS = "502";
            FILE_DATA_PORTS = "[$HTTP_PORTS,110,143]";
            FTP_PORTS = "21";
            GENEVE_PORTS = "6081";
            VXLAN_PORTS = "4789";
            TEREDO_PORTS = "3544";
          };
        };

        runmode = "workers";
        "host-mode" = "router";
        "default-log-dir" = "/var/log/suricata";
        nfq.mode = "accept";
        "af-packet" = [
          {
            interface = cfg.ppp;
            "cluster-id" = 99;
            "cluster-type" = "cluster_flow";
            defrag = true;
          }
        ];

        outputs = [
          {
            eve-log = {
              enabled = true;
              filetype = "regular";
              filename = "eve.json";
              "community-id" = true;
              types = [
                {
                  alert = {
                    "tagged-packets" = true;
                  };
                }
                {
                  http = {
                    extended = true;
                  };
                }
                {
                  dns = { };
                }
                {
                  tls = {
                    extended = true;
                  };
                }
                {
                  files = {
                    "force-magic" = false;
                  };
                }
                {
                  flow = { };
                }
                {
                  stats = {
                    totals = true;
                    threads = false;
                  };
                }
              ];
            };
          }
          {
            fast = {
              enabled = true;
              filename = "fast.log";
              append = true;
            };
          }
          {
            stats = {
              enabled = true;
              filename = "stats.log";
              append = true;
              totals = true;
              threads = false;
            };
          }
        ];

        threading = {
          "set-cpu-affinity" = false;
        };

        stream = {
          memcap = "64mb";
          "checksum-validation" = true;
          inline = "auto";
          reassembly = {
            memcap = "256mb";
            depth = "1mb";
            "toserver-chunk-size" = 2560;
            "toclient-chunk-size" = 2560;
          };
        };

        detect = {
          profile = "medium";
          "sgh-mpm-context" = "auto";
          "inspection-recursion-limit" = 3000;
        };

        "app-layer" = {
          protocols = {
            tls = {
              enabled = "yes";
              "detection-ports".dp = "443";
            };
            http.enabled = "yes";
            dns.enabled = "yes";
            ssh.enabled = "yes";
            smtp.enabled = "yes";
            ftp.enabled = "yes";
          };
        };

        stats = {
          enable = true;
          interval = "8";
        };

        "exception-policy" = "pass-flow";
      };
    };

    networking.nftables.enable = true;
    networking.nftables.tables.router-suricata = {
      family = "inet";
      content = ''
        chain forward_ips {
          type filter hook forward priority 10; policy accept;

          iifname "${cfg.lan0}" oifname "${cfg.ppp}" queue num ${queueNum} bypass comment "Queue LAN to WAN traffic for Suricata"
          iifname "${cfg.ppp}" oifname "${cfg.lan0}" queue num ${queueNum} bypass comment "Queue WAN to LAN traffic for Suricata"
        }
      '';
    };

    system.activationScripts.suricata-dirs.text = ''
      install -d -m 0755 -o ${config.services.suricata.settings.run-as.user} -g ${config.services.suricata.settings.run-as.group} /var/log/suricata
      install -d -m 0755 -o ${config.services.suricata.settings.run-as.user} -g ${config.services.suricata.settings.run-as.group} /var/lib/suricata
      install -d -m 0755 -o ${config.services.suricata.settings.run-as.user} -g ${config.services.suricata.settings.run-as.group} /var/lib/suricata/rules
    '';

    systemd.services.suricata = {
      after = [
        "network-online.target"
        pppdService
      ];
      wants = [ "network-online.target" ];
      partOf = [ pppdService ];
      bindsTo = [ pppdService ];
      serviceConfig = {
        ExecStart = lib.mkForce "!${config.services.suricata.package}/bin/suricata -c ${config.services.suricata.configFile} -q ${queueNum}";
        AmbientCapabilities = [
          "CAP_IPC_LOCK"
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
        ];
        CapabilityBoundingSet = [
          "CAP_IPC_LOCK"
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
        ];
        LimitNOFILE = 65536;
        LimitMEMLOCK = "infinity";
      };
    };

    systemd.services.suricata-update.serviceConfig.ExecStartPost = [
      "+${pkgs.systemd}/bin/systemctl -q --no-block try-reload-or-restart suricata.service"
    ];

    systemd.services.suricata-update.after = [ pppdService ];

    systemd.timers.suricata-update = {
      description = "Daily Suricata rule update";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    services.logrotate.settings.suricata = {
      files = "/var/log/suricata/*.log /var/log/suricata/*.json";
      frequency = "daily";
      rotate = 7;
      compress = true;
      copytruncate = true;
      missingok = true;
      notifempty = true;
    };
  };
}
