{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.personal.moshi;
in
{
  options.sifr.personal.moshi.enable =
    lib.mkEnableOption "moshi-hook daemon for the Moshi mobile app";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.moshi-hook ];

    home-manager.users."${vars.user}" = {
      systemd.user.services.moshi-hook = {
        Unit = {
          Description = "Moshi hook daemon";
          After = [ "network-online.target" ];
        };

        Service = {
          ExecStart = "${pkgs.moshi-hook}/bin/moshi-hook serve";
          Restart = "always";
          RestartSec = "5s";
          # The daemon spawns tmux sessions and agent CLIs, which must be
          # resolvable from the unit's minimal PATH.
          Environment = [
            "PATH=/run/wrappers/bin:/etc/profiles/per-user/${vars.user}/bin:/run/current-system/sw/bin"
          ];
        };

        Install.WantedBy = [ "default.target" ];
      };
    };
  };
}
