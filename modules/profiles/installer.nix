{
  config,
  pkgs,
  unstable,
  home-manager,
  lib,
  vars,
  ...
}:
with lib; let
  cfg = config.sifr.profiles;
in {
  options.sifr.profiles.installer = mkOption {
    description = "Installer profile";
    type = types.bool;
    default = false;
  };
  config = mkIf cfg.installer {
    sifr.graphics.i3.enable = mkDefault true;
    sifr.graphics.enableSound = mkDefault false;

    # Some configurations to reduce system size
    documentation.enable = lib.mkForce false;
    documentation.nixos.enable = lib.mkForce false;
    security.polkit.enable = lib.mkForce false;
    security.rtkit.enable = lib.mkForce false;
    security.apparmor.enable = lib.mkForce false;

    boot.supportedFilesystems = ["btrfs" "ntfs" "xfs"];

    # Installer packages
    environment.systemPackages = with pkgs; [
      parted
      nvme-cli
      pciutils
      usbutils
      gitMinimal
      zip
      unzip
      cryptsetup
    ];

    users.users."${vars.user}" = {
      # Allow passwordless login
      initialHashedPassword = "";
    };
    services.xserver.displayManager.autoLogin = {
      enable = true;
      user = "${vars.user}";
    };
    # Allow login to root with no password
    users.users.root.initialHashedPassword = "";

    # Add our custom installer script
    home-manager.users."${vars.user}" = {
      home.file.".bin/sifr-install" = {
        executable = true;
        text = builtins.readFile ../../lib/installer.sh;
      };
      xsession.windowManager.i3.config.startup = [
        {command = "alacritty -e 'sifr-install'";}
      ];
    };
  };
}
