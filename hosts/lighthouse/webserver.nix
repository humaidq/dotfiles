{
  ...
}:

{
  config = {
    # Open ports for Caddy
    networking.firewall.allowedTCPPorts = [
      443
      80
    ];

    # Extra hardening
    systemd.services.caddy.serviceConfig = {
      # Upstream already sets NoNewPrivileges, PrivateDevices, ProtectHome
      ProtectSystem = "strict";
      PrivateTmp = "yes";
    };

    services.caddy = {
      enable = true;
      email = "me.caddy@huma.id";
      virtualHosts = {
        "lighthouse.huma.id".extraConfig = ''
          respond "this is lighthouse"
        '';
      };
    };
  };
}
