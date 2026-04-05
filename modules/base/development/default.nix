{
  config,
  pkgs,
  lib,
  vars,
  ...
}:
let
  cfg = config.sifr.development;
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
          lfs.enable = true;
          settings = {
            user = {
              name = config.sifr.fullname;
              email = config.sifr.gitEmail;
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
          };
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
        zig
        #polyml
        #swi-prolog
        #ghc
        #haskellPackages.hoogle
        #ocaml

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

        # Nix
        nix-diff
        nix-fast-build
        nix-info
        nix-melt
        nix-tree
        nixfmt-rfc-style
        nixpkgs-review
        optinix # nix option search
        nix-search-cli # nix package search

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
