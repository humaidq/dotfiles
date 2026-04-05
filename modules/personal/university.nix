{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.sifr.personal.university.enable = lib.mkEnableOption "university tools";

  config = lib.mkIf config.sifr.personal.university.enable {
    environment.systemPackages = with pkgs; [
      zoom-us
      unstable.vscode-fhs
    ];

    programs.ssh = {
      extraConfig = ''
        Host student-lab
             HostName login-student-lab.mbzu.ae
             user humaid.alqasimi
      '';

      knownHosts = {
        student-lab = {
          hostNames = [ "login-student-lab.mbzu.ae" ];
          publicKey = "login-student-lab.mbzu.ae ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIZ3n5JsO8AuHy+E8ZRHvgmgVvD/3WBVNGwBqaNOJGyR";
        };
      };
    };
  };
}
