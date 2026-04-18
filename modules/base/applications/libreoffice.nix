{
  config,
  lib,
  pkgs,
  vars,
  ...
}:
let
  cfg = config.sifr.applications;
  loDefaults = pkgs.writeText "registrymodifications.xcu" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <oor:items xmlns:oor="http://openoffice.org/2001/registry">
      <item oor:path="/org.openoffice.Office.Common/Misc">
        <prop oor:name="ShowTipOfTheDay" oor:op="fuse">
          <value>false</value>
        </prop>
      </item>

      <item oor:path="/org.openoffice.Office.Writer/Layout/Other">
        <prop oor:name="MeasureUnit" oor:op="fuse">
          <value>2</value>
        </prop>
      </item>

      <item oor:path="/org.openoffice.Office.Calc/Layout/Other/MeasureUnit">
        <prop oor:name="Metric" oor:op="fuse">
          <value>2</value>
        </prop>
      </item>
    </oor:items>
  '';
in
{
  options.sifr.applications.libreoffice.enable = lib.mkOption {
    description = "Enables LibreOffice profile seeding";
    type = lib.types.bool;
    default = lib.attrByPath [ "sifr" "desktop" "apps" ] false config;
  };

  config = lib.mkIf cfg.libreoffice.enable {
    home-manager.users."${vars.user}" =
      { lib, ... }:
      {
        home.activation.seedLibreOfficeProfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          target="$HOME/.config/libreoffice/4/user/registrymodifications.xcu"
          if [ ! -e "$target" ]; then
            install -D -m 0644 ${loDefaults} "$target"
          fi
        '';
      };
  };
}
