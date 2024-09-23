{ config, lib, ... }:

let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    services.postgresql = {
      ensureUsers = [
        {
          name = "vaultwarden";
          ensureDBOwnership = true;
        }
        {
          name = "paperless";
          ensureDBOwnership = true;
        }
      ];
      ensureDatabases = [
        "vaultwarden"
        "paperless"
      ];
    };
    sops.secrets."vaultwarden/env" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "vaultwarden";
      mode = "600";
    };
    services.vaultwarden = {
      enable = true;
      dbBackend = "postgresql";
      config = {
        DOMAIN = "https://vault.alq.ae";
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = 8222;
        databaseUrl = "postgres:///vaultwarden?host=/var/run/postgresql";

        # Mail
        SMTP_HOST = "in-v3.mailjet.com";
        SMTP_PORT = 25;
        SMTP_SECURITY = "starttls";
        SMTP_FROM = "server@alq.ae";
        SMTP_FROM_NAME = "alq.ae Vaultwarden Server";
      };
      environmentFile = "${config.sops.secrets."vaultwarden/env".path}";
    };

    services.stirling-pdf = {
      enable = true;
      environment = {
        SERVER_PORT = 8084;
      };
    };

    services.invidious = {
      enable = true;
      domain = "yt.alq.ae";
      port = 4747;
      nginx.enable = true;
      settings = {
        domain = "yt.alq.ae";
        https_only = true;
        dark_mode = "dark";
        default_home = "Subscriptions";
        popular_enabled = false;
        feed_menu = [
          "Subscriptions"
          "Playlists"
        ];
        statistics_enabled = true;
        default_user_preferences = {
          quality = "dash";
          local = true;
          region = "AE";
          captions = [
            "English"
            "English (auto-generated)"
            "Arabic"
          ];
        };
      };
    };

    services.forgejo = {
      enable = true;
      database.type = "postgres";
      lfs.enable = true;
      settings = {
        DEFAULT.APP_NAME = "git.alq.ae";
        server = {
          DOMAIN = "git.alq.ae";
          ROOT_URL = "https://git.alq.ae/";
          HTTP_PORT = 3939;
          SSH_PORT = 2222;
          START_SSH_SERVER = true;
        };
      };
    };

    services.searx = {
      enable = true;
      settings = {
        server = {
          port = 4848;
          bind_address = "127.0.0.1";
          secret_key = "notsoultrasecretkey";
        };
        general.instance_name = "search.alq.ae";
        ui.theme_args.simple_style = "dark";
        search = {
          safe_search = 1;
          autocomplete = "google";
          default_lang = "en";
        };
        enabled_plugins = [
          "Hostnames plugin"
          "Unit converter plugin"
          "Open Access DOI rewrite"
        ];

        hostname_replace = {
          "(.*\.)?youtube\.com$" = "yt.alq.ae";
          "(.*\.)?youtu\.be$" = "yt.alq.ae";
        };
        doi_resolvers = {
          "sci-hub.se" = "https://sci-hub.se";
        };
        engines = [
          {
            name = "invidious";
            engine = "invidious";
            base_url = [
              "https://yt.alq.ae/"
            ];
            disabled = false;
          }
        ];
      };
    };

    services.paperless = {
      enable = true;
      settings = {
        PAPERLESS_CONSUMER_IGNORE_PATTERN = [
          ".DS_STORE/*"
          "desktop.ini"
        ];
        PAPERLESS_DBHOST = "/run/postgresql";
      };
    };

    sops.secrets."authentik/env" = {
      sopsFile = ../../secrets/home-server.yaml;
      mode = "600";
    };
    services.authentik = {
      enable = false;
      # The environmentFile needs to be on the target host!
      # Best use something like sops-nix or agenix to manage it
      environmentFile = config.sops.secrets."authentik/env".path;
      settings = {
        email = {
          host = "smtp.example.com";
          port = 587;
          username = "authentik@example.com";
          use_tls = true;
          use_ssl = false;
          from = "authentik@example.com";
        };
        disable_startup_analytics = true;
        avatars = "initials";
      };
      nginx = {
        enable = true;
        enableACME = false;
        host = "auth.alq.ae";
      };
    };

  };
}
