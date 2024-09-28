{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.development;
  allowedSigners = pkgs.writeText "allowed-signers" ''
    git@huma.id ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPx68Wz04/MkfKaptXlvghLjwnW3sTUXgZgiDD3Nytii git@huma.id
    humaid.alqassimi@tii.ae ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUlaLlxVlm1KZtoG3R/nHl/KJzmKaIyckDVE2rDJYH+ humaid.alqassimi@tii.ae
  '';
in
{
  options.sifr.development.enable = lib.mkOption {
    description = "Sets up the development environment, compilers, and tools";
    type = lib.types.bool;
    default = false;
  };

  imports = [ ./v12n.nix ];

  config = lib.mkMerge [
    {
      # We need basic git on all computers, needed for flakes too.
      home-manager.users."${vars.user}" = {
        programs.git = {
          enable = true;
          aliases = {
            co = "checkout";
          };
          includes = [
            {
              condition = "gitdir:~/tii/";
              contents = {
                user.email = "humaid.alqassimi@tii.ae";
                user.signingkey = "~/.ssh/id_ed25519_tii.pub";
                core.sshCommand = "ssh -i ~/.ssh/id_ed25519_tii";
              };
            }
          ];

          userName = "Humaid Alqasimi";
          userEmail = "git@huma.id";
          signing.key = "~/.ssh/id_ed25519.pub";
          signing.signByDefault = true;
          extraConfig = {
            core.editor = "nvim";
            init.defaultBranch = "main";

            format.signoff = true;
            commit.verbose = "yes";
            merge.conflictStyle = "zdiff3";

            push.default = "current";
            pull.rebase = true;

            # Sign commits with SSH key
            gpg.format = "ssh";
            gpg.ssh.allowedSignersFile = "${allowedSigners}";
            tag.gpgSign = true;
            commit.gpgSign = true;

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
      documentation = {
        dev.enable = true;
        man.generateCaches = true;
      };
      home-manager.users."${vars.user}" = {
        programs = {
          git = {
            package = pkgs.gitAndTools.gitFull;
            delta.enable = true;
          };

          direnv = {
            enable = true;
            enableZshIntegration = true;
            nix-direnv.enable = true;
          };
          nix-index-database.comma.enable = true;
          nix-index.enable = true;
        };

        editorconfig = {
          enable = true;
          settings = {
            "*" = {
              charset = "utf-8";
              end_of_line = "lf";
              trim_trailing_whitespace = true;
              insert_final_newline = true;
              indent_style = "space";
              indent_size = 2;
            };
            "*.go" = {
              indent_style = "tab";
            };
            "Makefile" = {
              indent_style = "tab";
            };
            "*.py" = {
              indent_size = 4;
            };
          };
        };
      };

      # Only include general helpful development tools
      environment.systemPackages = with pkgs; [
        bat
        bvi
        dmtx-utils
        ffmpeg
        gdb
        gnupg
        imagemagick
        licensor
        minify
        scc
        sqlite

        # git
        gh
        git-absorb
        git-extras
        git-lfs
        git-privacy
        tig

        # Nix
        nix-diff
        nix-fast-build
        nix-info
        nix-melt
        nix-output-monitor
        nix-tree
        nixfmt-rfc-style
        nixpkgs-review
      ];
    })
  ];
}
