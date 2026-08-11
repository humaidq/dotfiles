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
  killconn = pkgs.writeShellApplication {
    name = "killconn";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      conntrack-tools
    ];
    text = builtins.readFile ./killconn.bash;
  };
  tempblock = pkgs.writeShellApplication {
    name = "tempblock";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      nftables
    ];
    text = builtins.readFile ./tempblock.bash;
  };
  tempthrottle = pkgs.writeShellApplication {
    name = "tempthrottle";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnused
      iproute2
      nftables
    ];
    text = builtins.readFile ./tempthrottle.bash;
  };
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      clients
      killconn
      tempblock
      tempthrottle
    ];

    # router-web's peers page shells out to these to throttle/block a peer.
    # DynamicUser services (see web.nix) get a PATH built solely from their
    # own `path` list, not /run/current-system/sw/bin, so
    # environment.systemPackages above is not enough on its own to put these
    # on router-web's PATH.
    systemd.services.router-web.path = [
      killconn
      tempblock
      tempthrottle
    ];
  };
}
