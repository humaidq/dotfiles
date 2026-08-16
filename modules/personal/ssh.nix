{
  config,
  lib,
  vars,
  ...
}:
let
  # Touch-free development keys, one per machine that originates SSH. Each is a
  # non-resident FIDO credential minted on that machine's own YubiKey with
  # `-O no-touch-required`, so the private half never leaves the token and
  # nothing secret is shared between hosts or stored in this repo:
  #
  #   ssh-keygen -t ed25519-sk -O no-touch-required -O application=ssh:dev-<host> \
  #              -C dev-<host> -N "" -f ~/.ssh/id_ed25519_sk_dev
  #
  # The `no-touch-required` prefix below is NOT decoration. sshd checks the
  # user-presence bit on every signature and rejects the key outright unless the
  # authorized_keys entry opts in. Dropping the prefix produces an authentication
  # failure that looks nothing like its cause.
  #
  # These are weaker than the touch keys by design: anything running as the user
  # on the originating machine can use them silently. That is the point -- it is
  # what lets agents and remote sessions work unattended.
  devKeys = [
    "no-touch-required sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAILIgDij/HTlP53qhiklklAHvfSTkkqzxiTV2OFWIebucAAAADHNzaDpkZXYtYW5vYQ== dev-anoa"
  ];

  # Hosts that accept the dev keys, and therefore the only hosts the key is
  # offered to. Every name each one answers to has to be listed: ssh matches the
  # Host block against what you typed on the command line, not against the
  # resolved address, so `ssh 10.10.0.16` and `ssh bongo` need separate patterns.
  devHosts = [
    "oreamnos"
    "oreamnos.s.alq.ae"
    "10.10.0.12"
    "bongo"
    "bongo.s.alq.ae"
    "10.10.0.16"
    "bingo"
    "bingo.s.alq.ae"
    "10.10.0.18"
  ];
in
{
  options.sifr.personal.ssh.acceptDevKeys =
    lib.mkEnableOption "accepting touch-free development SSH keys";

  config = {
    services.openssh.settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };

    users.users.root.openssh.authorizedKeys.keys =
      lib.optionals config.sifr.personal.ssh.acceptDevKeys devKeys
      ++ [
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIC+JivWVZLN5Q+gQp+Y+YOHr0tglTPujT5uqz0Vk//YnAAAABHNzaDo= HK05"
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIBDT3fTXfORHii5qehplQUj0JQztBhELP9D+22/8cg+9AAAAD3NzaDpodW1haWQtYW5vYQ== humaid-nano-anoa-ssh-git"

        # termius
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLEmHSloW9GlnGAQWTf/bBgbDEhQ6NZCsbd3QKb/yJ+9GrVfq0yensVsoHlI4+Ozq01qs7bIXc4W6gPSmT4PAA0="
      ];

    programs.ssh.knownHosts = {
      oreamnos-ed = {
        hostNames = [
          "10.10.0.12"
          "oreamnos"
        ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHnC2ZPG75+HmEpS6OYpYU4OG6G8rwiEKDNXudtTAr0u";
      };
      oreamnos-rsa = {
        hostNames = [
          "oreamnos"
          "10.10.0.12"
        ];
        publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCR0gcBv3hUx0xxqlfsv4wUUuAL1/3KDOywcl7o/b00ABdF0IOKhgXGicxVegfrtgV8dhY+fb8CYBzlPfsy8/34+XM5PXQHus99WQ0obLEsoKH2EEMz3mRCt5RU2Dttv0mGNeadJXldNJS3IyqIxlj8nYyBZJFR4tMmKA8sE9l8EvRSV/OUxv9G9WiS/j/PYfhjJig1lbdqZtjPL5hbgQcIdSXZKJUxbhD3vR8hh+3JY5LKSEK5pWTAYGsOPXaU3NPLxDPWSwZJvF8jW/546y3jaeEEd3CBGZfziVQ4xWwtZlYzuCdKxhmABicRqfj0XsXitvF+P//G74/+LRhkqcz73UqfRRb9hH1aIhZf6SVGrXaemAwO01991uBqZBcbDfo7VwwiwhQt0JPJ+bAqqJPic5JB6fMdCyNoXA1x5/b1L8DRiZE9rOn1woReO6T1w0aXHFPRvLiNypENW45oYw8c/1a8wirruQbIR4ufVKbl+eTHy0e/U/dlpiTOVH2R5wbVZT53StRW4BGNozt4dUS7DJgE6fJAa0nTtC8QVsjGf5RpgCsnqxCynZECk6B48WPmmkqxnfU84LoONoxRTcwNlA6lWigDeA3rD1dJDLGEvPF5P7FkWXGCPDLS9ZymLDFAvygvhi3y9wcLimqlt8K4w5O/zgDNI0bLJ0hQCfUpMQ==";
      };
    };

    home-manager.users.${vars.user} = {
      programs.ssh.enable = true;
      programs.ssh.enableDefaultConfig = false;
      programs.ssh.settings."*" = {
        ForwardAgent = false;
        AddKeysToAgent = "no";
        Compression = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = false;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
      };

      # Scoped to the hosts that accept it rather than set on "*", so the key is
      # never offered to GitHub or any other third party. id_ed25519_sk_dev is
      # not one of ssh's built-in identity filenames, so without an explicit
      # IdentityFile it is never offered at all and every session silently falls
      # back to a touch key.
      #
      # Listed identities are tried ahead of the built-in defaults, which is what
      # puts the touch-free key in front of id_ed25519_sk. The server takes the
      # first key it accepts, so losing that race means a touch prompt even
      # though a no-touch key was available. IdentitiesOnly is deliberately not
      # set: if the dev key is missing or revoked, ssh falls through to the touch
      # keys and asks for a tap instead of failing to authenticate.
      #
      # The path is per-machine by convention -- each host mints its own key
      # here, and on hosts that have not, ssh just skips the missing file.
      programs.ssh.settings.${lib.concatStringsSep " " devHosts} = {
        IdentityFile = "~/.ssh/id_ed25519_sk_dev";
      };
      services.ssh-agent.enable = true;
    };
  };
}
