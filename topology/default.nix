{config, ...}: let
  inherit
    (config.lib.topology)
    mkDevice
    ;
in {
  nodes.printer = mkDevice "Printer Attic" {
    info = "Epson XP-7100";
  };
  #networks.home.name = "Home LAN";
}
