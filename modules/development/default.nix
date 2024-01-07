{
  self,
  config,
  pkgs,
  home-manager,
  unstable,
  lib,
  vars,
  ...
}:
with lib; let
  cfg = config.sifr.development;
in {
  options.sifr.development.enable = mkOption {
    description = "Sets up the development environment, compilers, and tools";
    type = types.bool;
    default = false;
  };

  config = mkMerge [
    (mkIf cfg.enable {
      home-manager.users."${vars.user}" = {
        programs.git = {
          enable = true;
          package = pkgs.gitAndTools.gitFull;
          aliases = {co = "checkout";};
          delta.enable = true;
          userName = "Humaid Alqasimi";
          userEmail = "git@huma.id";
          signing.key = "54C2007DB93B5EC5";
          signing.signByDefault = true;
          extraConfig = {
            core.editor = "nvim";
            init.defaultBranch = "master";
            format.signoff = true;
            commit.verbose = "yes";
            push.default = "current";
            pull.rebase = true;
            safe.directory = "/mnt/hgfs/*";
            url = {
              "git@github.com:".insteadOf = "gh:";
              "git@git.sr.ht:".insteadOf = "srht:";
            };

            # Mailer
            sendemail.smtpserver = "smtp.mail.me.com";
            sendemail.smtpuser = "me@huma.id";
            sendemail.smtpencryption = "tls";
            sendemail.smtpserverport = "587";
          };
        };
      };

      environment.systemPackages = with pkgs; [
        # compilers, interpreters, runtimes, etc
        unstable.go_1_21
        gcc
        rustc
        jre
        jdk
        lua
        sass
        lua52Packages.luarocks
        python311Full
        python311Packages.pip

        # utilities
        ffmpeg
        git-privacy
        git-lfs
        gdb
        bvi
        minify
        pkg-config
        licensor
        gnupg
        bat
        sqlite
        dmtx-utils
        fzf
        scc

        # build tools
        gnumake
        cmake
        cargo
        nodejs
        corepack_21

        # documentation, generators
        mdbook
        mdbook-mermaid
        mdbook-toc
        mdbook-pdf
        mdbook-katex
        pandoc
        unstable.hugo
        plantuml
        #nodePackages.mermaid-cli
        mermaid-cli
        graphviz
        texlive.combined.scheme-full
        tectonic
        imagemagick

        # sbom, compliance
        cyclonedx-gomod
        cyclonedx-python
        cdxgen

        # language servers, checkers, formatters
        shellcheck
        #cmake-language-server
        rust-analyzer
        nodePackages.pyright
        nodePackages.eslint
        nodePackages.stylelint
        nodePackages.bash-language-server
        nodePackages.vscode-json-languageserver
        nodePackages.dockerfile-language-server-nodejs
        nodePackages.typescript-language-server
        taplo
        lua-language-server
        prettierd
        hadolint
        tailwindcss-language-server
        vscode-langservers-extracted
        nodePackages.jsdoc
        # We use latest version of Go
        unstable.gopls
        unstable.gotools
        unstable.golangci-lint
        unstable.govulncheck
      ];
    })
  ];
}
