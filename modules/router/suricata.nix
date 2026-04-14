{
  config,
  lib,
  pkgs,
  ...
}:
let
  routerCfg = config.sifr.router;
  cfg = routerCfg.suricata;
  yaml = pkgs.formats.yaml { };
  python = pkgs.python3.withPackages (ps: with ps; [ pyyaml ]);
  suricataUpdate = "${python.interpreter} ${config.services.suricata.package}/bin/suricata-update";
  mkSourceName = url: "sifr-${builtins.substring 0 16 (builtins.hashString "sha256" url)}";
  renderedConfigFile =
    pkgs.runCommandLocal "suricata.yaml"
      {
        suricataSettings = yaml.generate "suricata-settings-raw.yaml" (
          lib.filterAttrsRecursive (_: value: value != null) config.services.suricata.settings
        );
      }
      ''
        printf '%s\n' '%YAML 1.1' '---' > "$out"
        cat "$suricataSettings" >> "$out"
      '';
  sourceCommands = lib.concatMapStringsSep "\n" (
    url:
    let
      sourceName = mkSourceName url;
    in
    ''
      ${suricataUpdate} remove-source ${sourceName} >/dev/null 2>&1 || true
      ${suricataUpdate} add-source --no-checksum ${sourceName} ${lib.escapeShellArg url}
    ''
  ) cfg.ruleUrls;
in
{
  options.sifr.router.suricata = {
    enable = lib.mkEnableOption "Suricata on the router";

    interfaces = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ routerCfg.lan0 ];
      description = "Interfaces for Suricata packet capture.";
    };

    ruleUrls = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ "https://feodotracker.abuse.ch/downloads/feodotracker.rules" ];
      description = "Custom remote Suricata rule feeds registered through suricata-update add-source.";
    };
  };

  config = lib.mkIf (routerCfg.enable && cfg.enable) {
    services.suricata = {
      enable = true;
      configFile = renderedConfigFile;
      enabledSources = [ ];
      settings = {
        af-packet = map (interface: { inherit interface; }) cfg.interfaces;
        classification-file = "${config.services.suricata.package}/etc/suricata/classification.config";
      };
    };

    systemd.services.suricata-update.preStart = sourceCommands;
  };
}
