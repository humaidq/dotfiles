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
    sops.secrets."step-ca/intermediate-password" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "step-ca";
      mode = "600";
    };
    sops.secrets."step-ca/root" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "step-ca";
      mode = "600";
    };
    sops.secrets."step-ca/crt" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "step-ca";
      mode = "600";
    };
    sops.secrets."step-ca/key" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "step-ca";
      mode = "600";
    };

    services.step-ca = {
      enable = true;
      address = "0.0.0.0";
      port = 8443;
      openFirewall = true;
      intermediatePasswordFile = config.sops.secrets."step-ca/intermediate-password".path;
      settings = {
        root = config.sops.secrets."step-ca/root".path;
        crt = config.sops.secrets."step-ca/crt".path;
        key = config.sops.secrets."step-ca/key".path;
        dnsNames = [
          "alq.ae"
          "huma.id"
          ".home.arpa"
        ];
        logger.format = "text";
        db = {
          type = "badgerv2";
          dataSource = "/var/lib/step-ca/db";
          badgerFileLoadingMode = "";
        };
        authority = {
          claims = {
            minTLSCertDuration = "5m";
            maxTLSCertDuration = "1080h";
            defaultTLSCertDuration = "1080h";
          };
          policy = {
            x509 = {
              allow = {
                dns = [
                  "*.alq.ae"
                  "alq.ae"
                  "huma.id"
                  "*.huma.id"
                  "home.arpa"
                  "*.home.arpa"
                ];
              };
              allowWildcardNames = true;
            };
          };
          provisioners = [
            {
              type = "ACME";
              name = "acme";
              forceCN = true;
            }
          ];
          backdate = "1m0s";
        };
        tls = {
          cipherSuites = [
            "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA"
            "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256"
            "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
            "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA"
            "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
            "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305"
            "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA"
            "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256"
            "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
            "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA"
            "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
            "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305"
          ];
          minVersion = 1.2;
          maxVersion = 1.3;
          renegotiation = false;
        };
      };
    };
  };
}
