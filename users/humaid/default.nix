{
  config,
  pkgs,
  ...
}: {
  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.humaid = {
    isNormalUser = true;
    uid = 1000;
    # wheel removed since we use doas
    extraGroups = [
      "plugdev"
      "dialout"
      "video"
      "audio"
      "docker"
      "disk"
      "networkmanager"
      "wheel"
      "lp"
      "kvm"
    ];
    description = "Humaid Alqasimi";
    shell = pkgs.zsh;
  };
  programs.zsh.enable = true;
}
