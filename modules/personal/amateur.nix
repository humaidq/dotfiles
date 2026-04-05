{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.personal.amateur;
in
{
  options.sifr.personal.amateur.enable = lib.mkEnableOption "personal amateur radio tools";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      unstable.wsjtx
      js8call
      fldigi
      flrig
      unstable.hamlib_4
      gridtracker
      gpredict
      unstable.qlog
      tqsl
      libusb1
      rtl-sdr
      sdrpp
      ax25-tools
      ax25-apps
      direwolf
      unixcw
    ];

    hardware.rtl-sdr.enable = true;

    services.pipewire.wireplumber.configPackages = [
      (pkgs.writeTextDir "share/wireplumber/wireplumber.conf.d/50-digirig.conf" ''
        monitor.alsa.rules = [
          {
            matches = [
              {
                node.name = "alsa_output.usb-C-Media_Electronics_Inc._USB_Audio_Device-00.iec958-stereo"
              }
            ]
            actions = {
              update-props = {
                node.nick  = "Digirig Output"
                node.description  = "Digirig Output"
                node.volume = 1
              }
            }
          }
          {
            matches = [
              {
                node.name = "alsa_input.usb-C-Media_Electronics_Inc._USB_Audio_Device-00.mono-fallback"
              }
            ]
            actions = {
              update-props = {
                node.nick  = "Digirig Input"
                node.description  = "Digirig Input"
                node.volume = 1
              }
            }
          }
        ]
      '')
    ];
  };
}
