{ lib, config, pkgs, ... }: {
  imports = [
    ../common
  ];

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };
  boot.initrd.secrets = {
    "/crypto_keyfile.bin" = null;
  };

  networking.networkmanager.enable = true;
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  virtualisation.docker.enable = true;

  # My configuration specific settings
  hsys = {
    workProfile = true;
    enablei3 = true;
    getDevTools = true;
    laptop = false;

    tailscale = {
      enable = false;
      exitNode = true;
      ssh = true;

      # temp
      #auth = true;
      #tsKey = "tskey-kKX8n35CNTRL-A76BPGh8jqVkuVFHWA3YJ";
    };
  };

  services.udev.extraRules = ''ACTION=="change", SUBSYSTEM=="drm", RUN+="${pkgs.autorandr}/bin/autorandr -c"'';
  services.autorandr = {
    enable = true;
    
    profiles = {
      "dock" = {
        fingerprint = {
          "HDMI-1" = "00ffffffffffff0030aecb620000000026200103803c22788ac815af4f36bb260d5054a1080081c0810081809500a9c0b300d1c0d1004dd000a0f0703e803020350055502100001a000000fc00503237752d32300a2020202020000000fd0032461e8c3c000a202020202020000000ff0056393042373842310a20202020017a020337f14801030204105e5f6123097f07830100006c030c001000383c200040010267d85dc401788803e305c301e10fe60607016c4e31e26800a0a0402e603020360055502100001a565e00a0a0a029503020350055502100001a000000000000000000000000000000000000000000000000000000000000000000000000ac";
          "eDP-1" = "00ffffffffffff0009e5c80600000000011a0101951c107802b09097585492261d505400000001010101010101010101010101010101641b56775000133030204400159c1000001a8417568051005c3064644405159c1000001a000000fe003248593734804e5431324e34320000000000004101940010000009010a202000af";
        };
        config = {
          "eDP-1".enable = false;
          "HDMI-1" = {
            enable = true;
            primary = true;
            position = "0x0";
            mode = "2560x1440";
            rate = "59.95";
          };
        };
      };
      "laptop" = {
        fingerprint = {
          "eDP-1" = "00ffffffffffff0009e5c80600000000011a0101951c107802b09097585492261d505400000001010101010101010101010101010101641b56775000133030204400159c1000001a8417568051005c3064644405159c1000001a000000fe003248593734804e5431324e34320000000000004101940010000009010a202000af";
        };
        config = {
          "eDP-1" = {
            enable = true;
            primary = true;
            mode = "1280x720";
            position = "0x0";
            rate = "60";
          };
        };
      };
    };
    # Make this global?
    hooks = {
      postswitch = {
        "notify-i3" = "${pkgs.i3}/bin/i3-msg restart";
        # TODO update wallpaper
      };
    };
  };

  system.stateVersion = "23.05";
}
