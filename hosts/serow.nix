{...}: {
  boot.loader = {
    systemd-boot = {
      enable = true;
      memtest86.enable = true;
      consoleMode = "auto";
    };

    efi.canTouchEfiVariables = true;
  };

  # My configuration specific settings
  sifr = {
    graphics = {
      gnome.enable = true;
      apps = true;
    };
    profiles.basePlus = true;
    profiles.laptop = true;
    development.enable = true;
    security.yubikey = true;
    v18n.emulation.enable = true;
    v18n.emulation.systems = ["aarch64-linux"];

    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;
      auth = true;
    };
  };

  virtualisation.virtualbox.host.enable = true;
}
