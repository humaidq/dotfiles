{ config, lib, ... }:

let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    services.postgresql = {
      ensureUsers = [
        {
          name = "paperless";
          ensureDBOwnership = true;
        }
      ];
      ensureDatabases = [
        "paperless"
      ];
    };

    services.stirling-pdf = {
      enable = true;
      environment = {
        SERVER_PORT = 8084;
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

          LANDING_PAGE = "explore";
        };
        repository = {
          DEFAULT_PRIVATE = "private";
          ENABLE_PUSH_CREATE_USER = true;
          ENABLE_PUSH_CREATE_ORG = true;
        };
        "repository.pull-request" = {
          DEFAULT_MERGE_STYLE = "rebase";
        };
        other = {
          SHOW_FOOTER_TEMPLATE_LOAD_TIME = false;
          SHOW_FOOTER_VERSION = false;
        };
        "ui.meta" = {
          AUTHOR = "git.alq.ae";
          DESCRIPTION = "A private software forge";
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
          #formats = [ "html" "json"];
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

    services.seafile = {
      enable = false;
      adminEmail = "me@huma.id";
      initialAdminPassword = "admin";
      ccnetSettings.General.SERVICE_URL = "https://seafile.alq.ae";
      seafileSettings = {
        fileserver.port = 3012;
      };
    };

    services.paperless = {
      enable = true;
      dataDir = "/persist-svc/paperless";
      passwordFile = config.sops.secrets."paperless/su-pass".path;
      settings = {
        PAPERLESS_CONSUMER_IGNORE_PATTERN = [
          ".DS_STORE/*"
          "desktop.ini"
        ];
        PAPERLESS_DBHOST = "/run/postgresql";
        PAPERLESS_URL = "https://paperless.alq.ae";
        PAPERLESS_USE_X_FORWARD_HOST = true;
        PAPERLESS_USE_X_FORWARD_PORT = true;
      };
    };

    sops.secrets."paperless/su-pass" = {
      sopsFile = ../../secrets/home-server.yaml;
      mode = "600";
    };
    sops.secrets."authentik/env" = {
      sopsFile = ../../secrets/home-server.yaml;
      mode = "600";
    };
    services.authentik = {
      enable = true;
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
