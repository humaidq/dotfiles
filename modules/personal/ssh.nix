{ vars, ... }:
{
  config = {
    users.users.root.openssh.authorizedKeys.keys = [
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIC+JivWVZLN5Q+gQp+Y+YOHr0tglTPujT5uqz0Vk//YnAAAABHNzaDo= HK05"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPfxi0RMhH9Jtlbe+PIGwO9IJjp6T5wC+33v+oYZrbMg humaid.alqasimi@LM007578"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLEmHSloW9GlnGAQWTf/bBgbDEhQ6NZCsbd3QKb/yJ+9GrVfq0yensVsoHlI4+Ozq01qs7bIXc4W6gPSmT4PAA0="
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPx68Wz04/MkfKaptXlvghLjwnW3sTUXgZgiDD3Nytii humaid@goral"
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
      programs.ssh.matchBlocks."*" = {
        forwardAgent = false;
        addKeysToAgent = "no";
        compression = false;
        serverAliveInterval = 0;
        serverAliveCountMax = 3;
        hashKnownHosts = false;
        userKnownHostsFile = "~/.ssh/known_hosts";
        controlMaster = "no";
        controlPath = "~/.ssh/master-%r@%n:%p";
        controlPersist = "no";
      };
      services.ssh-agent.enable = true;
    };
  };
}
