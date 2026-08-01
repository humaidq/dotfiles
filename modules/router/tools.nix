{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.router;
  clients = pkgs.writeShellApplication {
    name = "clients";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      iproute2
    ];
    text =
      lib.optionalString (cfg.dhcp.hostsFile != null) ''
        export HOSTS_FILE=${lib.escapeShellArg cfg.dhcp.hostsFile}
      ''
      + builtins.readFile ./clients.bash;
  };
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ clients ];
  };
}
