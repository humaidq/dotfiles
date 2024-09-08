{ vars, lib, ... }:

{
  # impermanence setup
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/var/lib/sops-nix"
      "/var/lib/ollama"
      "/var/lib/chrony"
      "/var/lib/tailscale"
      "/var/lib/grafana"
      {
        directory = "/var/lib/hydra";
        user = "hydra";
        mode = "0700";
      }
      "/var/lib/loki"
      "/var/lib/prometheus2"
      #"/var/lib/private/AdGuardHome"
      #"/var/lib/private/jellyseerr"
      #"/var/lib/private/lldap"
      #"/var/lib/private/mealie"
      #"/var/lib/private/prowlarr"

      {
        directory = "/var/lib/private";
        mode = "0700";
      }
      "/var/lib/radarr"
      "/var/lib/postgresql"
      {
        directory = "/var/lib/kavita";
        user = "kavita";
        mode = "0700";
      }
      {
        directory = "/var/lib/jellyfin";
        user = "jellyfin";
        mode = "0700";
      }
      "/var/lib/deluge"
      "/var/lib/caddy"
      "/var/lib/audiobookshelf"
      "/var/lib/uptimed"
      "/etc/NetworkManager/system-connections"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
    ];
    users."${vars.user}" = {
      directories = [
        "inbox"
        "repos"
        "tii"
        "docs"
        {
          directory = ".ssh";
          mode = "0700";
        }
        ".mozilla"
        ".local/share/direnv"
        ".config/sops"
        ".config/emacs"
        ".config/doom"
      ];
      files = [ ".config/zsh/.zsh_history" ];
    };
  };
  # sops loads before impermanence mounts are
  sops.age.keyFile = lib.mkForce "/persist/var/lib/sops-nix/key.txt";

  fileSystems."/persist".neededForBoot = true;

  # Reset root on every boot
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    zfs rollback -r rpool/root@blank
  '';
}
