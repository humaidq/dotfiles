{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.applications;
in
{

  options.sifr.applications.amateur.enable = lib.mkEnableOption "amateur radio tools";

  config = lib.mkIf cfg.amateur.enable {
    environment.systemPackages = with pkgs; [
      # digital modes
      unstable.wsjtx
      js8call
      fldigi
      # rig control
      flrig
      unstable.hamlib_4
      # mapping
      gridtracker
      gpredict
      # logging
      unstable.qlog
      tqsl
      # sdr
      gnuradio
      libusb1
      rtl-sdr
      gqrx
      sdrpp
      # ax.25
      ax25-tools
      ax25-apps
      direwolf
    ];

    hardware.rtl-sdr.enable = true;
    boot.kernelPatches = lib.singleton {
      name = "ax25-ham";
      patch = null;
      extraStructuredConfig = with lib.kernel; {
        HAMRADIO = yes;
        AX25 = yes;
        AX25_DAMA_SLAVE = yes;
      };
    };

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
                node.volume = 0.5
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

    # home-manager.users."${vars.user}" = {
    #   xdg.configFile."wireplumber/wireplumber.conf.d/50-digirig.conf".text = ''
    #     monitor.alsa.rules = [
    #       {
    #         matches = [
    #           {
    #             node.name = "alsa_output.usb-C-Media_Electronics_Inc._USB_Audio_Device-00.iec958-stereo"
    #           }
    #         ]
    #         actions = {
    #           update-props = {
    #             ["node.nick"]  = "Digirig Output"
    #             ["node.description"] = "Digirig Output"
    #             ["node.volume"] = 0.5
    #           }
    #         }
    #       }
    #     ]
    #   '';
    # };
  };
}
