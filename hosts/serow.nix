{
  config,
  pkgs,
  nixpkgs-unstable,
  vars,
  ...
}: {
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
      i3.enable = true;
      gnome.enable = true;
    };
    profiles.basePlus = true;
    profiles.laptop = true;
    development.enable = true;
    security.yubikey = true;
    v18n.emulation.enable = true;
    v18n.emulation.systems = ["aarch64-linux"];

    #virtualisation = true;
    tailscale = {
      enable = true;
      exitNode = true;
      ssh = true;

      auth = true;
      tsKey = "tskey-auth-keeYRk6CNTRL-RiXjZ1RP3Qi3HrSxW48oRiF6rQYUsswuV";
    };
  };
}
