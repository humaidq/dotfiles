{
  config,
  lib,
  vars,
  ...
}:
{
  options.sifr.personal.work.enable = lib.mkEnableOption "work settings";

  config = lib.mkIf config.sifr.personal.work.enable {
    home-manager.users."${vars.user}" = {
      programs.ssh.settings = {
        "ghafa-orin" = {
          HostName = "192.168.1.148";
          User = "root";
          IdentityFile = "/home/humaid/.ssh/id_ed25519_ghaf";
          CheckHostIP = false;
          StrictHostKeyChecking = "no";
          UserKnownHostsFile = "/dev/null";
        };
        "groot" = {
          User = "root";
          HostName = "192.168.1.227";
          CheckHostIP = false;
          IdentityFile = "/home/humaid/.ssh/id_ed25519_ghaf";
          StrictHostKeyChecking = "no";
          UserKnownHostsFile = "/dev/null";
        };
        "ghafa" = {
          User = "root";
          HostName = "192.168.100.2";
          ProxyJump = "ghafajump";
          CheckHostIP = false;
          IdentityFile = "/home/humaid/.ssh/id_ed25519_ghaf";
          StrictHostKeyChecking = "no";
          UserKnownHostsFile = "/dev/null";
        };
        "ghafajump" = {
          HostName = "192.168.1.227";
          IdentityFile = "/home/humaid/.ssh/id_ed25519_ghaf";
          StrictHostKeyChecking = "no";
          UserKnownHostsFile = "/dev/null";
          User = "ghaf";
          CheckHostIP = false;
        };
      };
    };

    programs.ssh = {
      extraConfig = ''
        Host awsarm
             HostName awsarm.vedenemo.dev
             Port 20220
             user humaid
             IdentityFile /home/humaid/.ssh/id_ed25519_ghaf
        Host hetzarm
             user humaid
             HostName 65.21.20.242
             IdentityFile /home/humaid/.ssh/id_ed25519_ghaf
        Host vedenemo-builder
             user humaid
             hostname builder.vedenemo.dev
             IdentityFile /home/humaid/.ssh/id_ed25519_ghaf
      '';

      knownHosts = {
        vedenemo-builder = {
          hostNames = [ "builder.vedenemo.dev" ];
          publicKey = "builder.vedenemo.dev ssh-ed25519 AAAAC3NzaC1    lZDI1NTE5AAAAIHSI8s/wefXiD2h3I3mIRdK+d9yDGMn0qS5fpKDnSGqj";
        };
        hetzarm-ed25519 = {
          hostNames = [ "65.21.20.242" ];
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILx4zU4gIkTY/1oKEOkf9gTJChdx/jR3lDgZ7p/c7LEK";
        };
        awsarm = {
          hostNames = [ "awsarm.vedenemo.dev" ];
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL3f7tAAO3Fc+8BqemsBQc/Yl/NmRfyhzr5SFOSKqrv0";
        };
      };
    };
  };
}
