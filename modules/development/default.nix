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
    git@huma.id sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIC+JivWVZLN5Q+gQp+Y+YOHr0tglTPujT5uqz0Vk//YnAAAABHNzaDo=
    humaid.alqassimi@tii.ae sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIM//VbFc8diwQ7MTRLGzKNd/Jghtd5w1o+eOJD0skwCmAAAAB3NzaDpUSUk=

    bmg.avoin@gmail.com sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIEJ9ewKwo5FLj6zE30KnTn8+nw7aKdei9SeTwaAeRdJDAAAABHNzaDo=
    bmg.avoin@gmail.com sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIA/pwHnzGNM+ZU4lANGROTRe2ZHbes7cnZn72Oeun/MCAAAABHNzaDo=
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

        programs.jujutsu = {
          enable = false;
          settings = {
            user = {
              name = "Humaid Alqasimi";
              email = "git@huma.id";
            };

            signing = {
              sign-all = true;
              backend = "ssh";
              key = "~/.ssh/id_ed25519_sk.pub";
            };

            "--scope" = [
              {
                "--when" = {
                  repositories = [ "~/repos/tii" ];
                };
                user.email = "humaid.alqassimi@tii.ae";
                signing.key = "~/.ssh/id_ed25519_sk_tii.pub";
                signing.backends.ssh.program = "ssh -i ~/.ssh/id_ed25519_sk_tii";
              }
            ];
          };
        };

        programs.git = {
          enable = true;
          lfs.enable = true;
          settings = {

            user = {
              name = "Humaid Alqasimi";
              email = "git@huma.id";
            };
            alias = {
              co = "checkout";
            };

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
            sendemail = {
              smtpserver = "smtp.migadu.com";
              smtpuser = "me@huma.id";
              smtpencryption = "tls";
              smtpserverport = "587";
            };
          };
          includes = [
            {
              condition = "gitdir:~/repos/tii/";
              contents = {
                user.email = "humaid.alqassimi@tii.ae";
                user.signingkey = "~/.ssh/id_ed25519_sk_rk_TII.pub";
                core.sshCommand = "ssh -i ~/.ssh/id_ed25519_sk_rk_TII";
                commit.gpgSign = true;
              };
            }
          ];

          signing.key = "~/.ssh/id_ed25519_sk.pub";
          signing.signByDefault = true;
        };
      };
    }
    (lib.mkIf cfg.enable {
      documentation = {
        dev.enable = true;
        #man.generateCaches = true;
      };
      home-manager.users."${vars.user}" = {
        programs = {
          git = {
            package = pkgs.gitFull;
          };
          delta.enable = true; # for git

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

      # Fix apps like jupyter
      programs.nix-ld = {
        enable = true;
        libraries = with pkgs; [
          stdenv.cc.cc.lib # provides libstdc++.so.6
          zlib
          openssl
          libffi
          glib
        ];
      };

      # Only include general helpful development tools
      environment.systemPackages = with pkgs; [
        # Basic compilers
        # (so no need devshell for fun projects)
        gcc
        clang
        clang-tools
        go
        nodejs
        rustc
        cargo
        rust-analyzer
        python3
        uv
        libllvm
        polyml
        zig
        swi-prolog
        #ghc
        #haskellPackages.hoogle
        ocaml

        gnumake
        cmake

        plantuml
        graphviz
        jdk
        pandoc
        bat
        bvi
        dmtx-utils
        ffmpeg
        gdb
        gnupg
        imagemagick
        reuse
        minify
        scc
        sqlite
        valgrind
        rlwrap
        shfmt
        shellcheck

        # git
        gh
        git-absorb
        git-extras
        git-lfs
        git-privacy
        #jujutsu
        #tig

        # Nix
        nix-diff
        nix-fast-build
        nix-info
        nix-melt
        nix-tree
        nixfmt-rfc-style
        nixpkgs-review
        optinix

        # other tools
        pnpm
        nodejs
        tree-sitter

        # AI
        unstable.claude-code
        unstable.opencode
      ];
    })
  ];
}
