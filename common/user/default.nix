{config, pkgs, ...}:

{
  imports = [ <home-manager/nixos> ];

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.humaid = {
    isNormalUser = true;
    uid = 1000;
    # wheel removed since we use doas
    extraGroups = [ "plugdev" "dialout" "wireshark" "video" "audio" "docker"
      "vboxusers" ];
    description = "Humaid AlQassimi";
    shell = pkgs.zsh;
  };

  home-manager.users.humaid = (import ./home-manager.nix);
}
