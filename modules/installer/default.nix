{
  config,
  lib,
  vars,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.sifr.installer;
  disko = inputs.disko.packages.${pkgs.stdenv.hostPlatform.system}.default;
  flakeRef = ''github:humaidq/dotfiles#"$1"'';

  sifr-disko = pkgs.writeShellApplication {
    name = "sifr-disko";
    runtimeInputs = [ disko ];
    text = ''
      if [ $# -ne 1 ]; then
        echo "Usage: sifr-disko <hostname>" >&2
        exit 1
      fi
      sudo disko --mode destroy,format,mount --flake ${flakeRef}
    '';
  };

  sifr-install = pkgs.writeShellApplication {
    name = "sifr-install";
    text = ''
      if [ $# -ne 1 ]; then
        echo "Usage: sifr-install <hostname>" >&2
        exit 1
      fi
      sudo nixos-install --root /mnt --flake ${flakeRef}
    '';
  };

  sifr-hwconfig = pkgs.writeShellApplication {
    name = "sifr-hwconfig";
    runtimeInputs = with pkgs; [
      nixos-install-tools
      iproute2
      jq
    ];
    text = ''
      if [ $# -ne 1 ]; then
        echo "Usage: sifr-hwconfig <hostname>" >&2
        exit 1
      fi
      host="$1"
      out="/srv/installer/$host.nix"
      sudo mkdir -p /srv/installer
      sudo chown nginx:nginx /srv/installer
      sudo sh -c "nixos-generate-config --root /mnt --show-hardware-config > '$out'"
      sudo chmod 0644 "$out"
      echo "Wrote $out"
      echo ""
      echo "Reachable at:"
      ip -j addr show \
        | jq -r '.[] | select(.ifname != "lo") | .addr_info[]? | select(.family == "inet") | .local' \
        | while read -r addr; do
            echo "  http://$addr/$host.nix"
          done
    '';
  };
in
{
  options.sifr.installer.enable = lib.mkEnableOption "installer profile";

  config = lib.mkIf cfg.enable {
    environment.variables.NIX_CONFIG = "tarball-ttl = 0";

    services.greetd.settings.initial_session = {
      command = lib.getExe pkgs.sway;
      inherit (vars) user;
    };
    boot.supportedFilesystems = {
      zfs = lib.mkForce true;
    };
    hardware.enableRedistributableFirmware = true;
    services.openssh.enable = true;
    networking.firewall.enable = false;
    services.getty.autologinUser = lib.mkForce vars.user;
    security.sudo-rs.enable = lib.mkForce false;
    security.sudo.wheelNeedsPassword = false;
    environment.systemPackages = [
      disko
      sifr-disko
      sifr-install
      sifr-hwconfig
    ];

    services.nginx = {
      enable = true;
      virtualHosts."installer" = {
        default = true;
        root = "/srv/installer";
        locations."/".extraConfig = "autoindex on;";
      };
    };
    systemd.tmpfiles.rules = [ "d /srv/installer 0755 nginx nginx -" ];

    sifr.bootstrap = true;

    home-manager.users.${vars.user} = {
      programs.swaylock.enable = lib.mkForce false;
      services.swayidle.enable = lib.mkForce false;
      wayland.windowManager.sway.config.keybindings."Mod4+l" = lib.mkForce "nop";
      programs.zsh.initContent = lib.mkAfter ''
        echo ""
        echo "  sifrOS installer ready."
        echo "  Workflow:"
        echo "    1. sifr-disko <host>      partition + format + mount on /mnt"
        echo "    2. sifr-hwconfig <host>   write hardware.nix, publish on LAN nginx"
        echo "    3. sifr-install <host>    install from github:humaidq/dotfiles#<host>"
        echo ""
      '';
    };
  };
}
