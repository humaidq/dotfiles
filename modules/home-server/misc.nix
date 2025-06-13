{ config, lib, ... }:

let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
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

  };
}
