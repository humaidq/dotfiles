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
          extraConfig = {
            core.editor = "nvim";
            init.defaultBranch = "master";
            format.signoff = true;
            commit.verbose = "yes";
            push.default = "current";
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
        lua52Packages.luarocks
        python311Full
        python311Packages.pip

        # utilities
        ffmpeg-full
        git-privacy
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
        ripgrep-all

        # build tools
        gnumake
        cmake
        cargo
        nodejs

        # documentation, generators
        mdbook
        pandoc
        hugo
        plantuml
        nodePackages.mermaid-cli
        graphviz
        texlive.combined.scheme-full
        tectonic

        # language servers, checkers, formatters
        shellcheck
        #cmake-language-server
        rust-analyzer
        unstable.gopls
        unstable.gotools
        unstable.golangci-lint
        unstable.govulncheck
        nodePackages.pyright
        nodePackages.eslint
        nodePackages.stylelint
        nodePackages.bash-language-server
        nodePackages.vscode-json-languageserver
        nodePackages.dockerfile-language-server-nodejs
        taplo
        lua-language-server
      ];
    })
  ];
}
