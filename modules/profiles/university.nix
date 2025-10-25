{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.profiles;
in
{
  options.sifr.profiles = {
    university = lib.mkEnableOption "university profile";
  };
  config = lib.mkIf cfg.university {
    #hardware.printers.ensurePrinters = [
    #  {
    #    name = "MBZUAI";
    #    #model = "${./assets/taskalfa4053ci-driverless-cupsfilters.ppd}";
    #    location = "MBZUAI Any Printer";
    #    deviceUri = "lpd://10.127.128.6/CM";
    #    ppdOptions = {
    #      PageSize = "A4";
    #    };
    #  }
    #];

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
