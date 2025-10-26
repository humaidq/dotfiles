{
  config,
  lib,
  ...
}:

let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    services.dokuwiki.sites."wiki.alq.ae" = {
      settings = {
        title = "Home Wiki";
        useacl = true;
        superuser = "@admin";
      };
    };
    sops.secrets."dokuwiki/smtp_pass" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "dokuwiki";
      mode = "600";
    };
  };
}
