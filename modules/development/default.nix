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
    (lib.mkIf cfg.enable {
      home-manager.users."${vars.user}" = {
        programs.git = {
          enable = true;
          package = pkgs.gitAndTools.gitFull;
          aliases = {co = "checkout";};
          delta.enable = true;
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

      # TODO Can we remove all this once we move to devshells?
      environment.systemPackages = with pkgs; [
        # compilers, interpreters, runtimes, etc
        go_1_21
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
        #pkg-config
        licensor
        gnupg
        bat
        sqlite
        dmtx-utils
        fzf
        scc
        nix-output-monitor

        # build tools
        gnumake
        cmake
        cargo
        #nodejs
        #corepack_21

        # documentation, generators
        #mdbook
        #mdbook-mermaid
        #mdbook-toc
        #mdbook-pdf
        #mdbook-katex
        #pandoc
        #unstable.hugo
        #plantuml
        #nodePackages.mermaid-cli
        #mermaid-cli
        #graphviz
        #texlive.combined.scheme-full
        #tectonic
        imagemagick

        # sbom, compliance
        #cyclonedx-gomod
        #cyclonedx-python
        #cdxgen

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
        nixd
        nil
        tailwindcss-language-server
        vscode-langservers-extracted
        nodePackages.jsdoc
        # We use latest version of Go
        gopls
        gotools
        golangci-lint
        govulncheck
      ];
    })
  ];
}
