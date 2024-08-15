{config, ...}: let
  inherit
    (config.lib.topology)
    mkInternet
    mkDevice
    mkSwitch
    mkRouter
    mkConnection
    ;
in {
  nodes.serow = mkDevice {
    info = "ThinkPad T590";
  };
}
