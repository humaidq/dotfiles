{
  config,
  pkgs,
  lib,
  vars,
  ...
}: let
  cfg = config.sifr.development;
  personalGitConfig = pkgs.writeText "personal-git-config" ''
    [user]
      email = git@huma.id
      signingkey = ~/.ssh/id_ed25519.pub
    [commit]
      gpgSign = true
    [tag]
      gpgSign = true
  '';
  tiiGitConfig = pkgs.writeText "tii-git-config" ''
    [user]
      email = humaid.alqassimi@tii.ae
      signingkey = ~/.ssh/id_ed25519_tii.pub
    [commit]
      gpgSign = true
    [tag]
      gpgSign = true
    [core]
      sshCommand = "ssh -i ~/.ssh/id_ed25519_tii"
  '';
  allowedSigners = pkgs.writeText "allowed-signers" ''
    git@huma.id ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPx68Wz04/MkfKaptXlvghLjwnW3sTUXgZgiDD3Nytii git@huma.id
    humaid.alqassimi@tii.ae ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUlaLlxVlm1KZtoG3R/nHl/KJzmKaIyckDVE2rDJYH+ humaid.alqassimi@tii.ae
  '';
in {
  options.sifr.development.enable = lib.mkOption {
    description = "Sets up the development environment, compilers, and tools";
    type = lib.types.bool;
    default = false;
  };

  config = lib.mkMerge [
    {
      # We need basic git on all computers, needed for flakes too.
      home-manager.users."${vars.user}" = {
        programs.git = {
          enable = true;
          aliases = {co = "checkout";};
          userName = "Humaid Alqasimi";
          extraConfig = {
            core.editor = "nvim";
            init.defaultBranch = "master";
            format.signoff = true;
            commit.verbose = "yes";
            push.default = "current";
            pull.rebase = true;
            gpg.format = "ssh";
            gpg.ssh.allowedSignersFile = "${allowedSigners}";
            #safe.directory = "/mnt/hgfs/*";
            url = {
              "git@github.com:".insteadOf = "gh:";
              "git@git.sr.ht:".insteadOf = "srht:";
            };

            includeIf."gitdir:/".path = "${personalGitConfig}";
            includeIf."gitdir:~/tii/".path = "${tiiGitConfig}";

            # Mailer
            sendemail.smtpserver = "smtp.mail.me.com";
            sendemail.smtpuser = "me@huma.id";
            sendemail.smtpencryption = "tls";
            sendemail.smtpserverport = "587";
          };
        };
      };
    }
    (lib.mkIf cfg.enable {
      home-manager.users."${vars.user}" = {
        programs.git = {
          package = pkgs.gitAndTools.gitFull;
          delta.enable = true;
        };

        programs.direnv = {
          enable = true;
          enableZshIntegration = true;
          nix-direnv.enable = true;
          #nix-direnv.package = unstable.nix-direnv;
          #package = unstable.direnv;
        };
        programs.nix-index-database.comma.enable = true;
        programs.nix-index.enable = true;
      };

      # Only include general helpful development tools
      environment.systemPackages = with pkgs; [
        ffmpeg
        git-privacy
        git-lfs
        gdb
        bvi
        minify
        licensor
        gnupg
        bat
        sqlite
        dmtx-utils
        scc
        nix-output-monitor
        imagemagick
        gh
      ];
    })
  ];
}
