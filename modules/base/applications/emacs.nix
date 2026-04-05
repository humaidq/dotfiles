{
  config,
  lib,
  vars,
  pkgs,
  ...
}:
let
  cfg = config.sifr.applications;
  emacs =
    with pkgs;
    ((emacsPackagesFor emacs30-pgtk).emacsWithPackages (
      epkgs: with epkgs; [
        treesit-grammars.with-all-grammars
        vterm
        pdf-tools
        org-pdftools
      ]
    ));
in
{
  options.sifr.applications.emacs.enable = lib.mkOption {
    description = "Enable emacs configuration";
    type = lib.types.bool;
    default = false;
  };
  config = lib.mkIf cfg.emacs.enable {
    services.emacs = {
      enable = true;
      package = emacs;
    };

    home-manager.users."${vars.user}" = {
      services.emacs = {
        client.enable = true;
      };
    };

    services.languagetool.enable = true;

    environment.systemPackages = [
      emacs
    ]
    ++ (with pkgs; [
      # :term vterm
      #gnumake
      #cmake
      copilot-language-server

      # :tools editorconfig
      editorconfig-core-c

      # :tools docker
      dockerfile-language-server
      dockfmt

      # :lang haskell
      # haskell-language-server #disable for now

      # :lang ocaml
      ocamlformat
      dune
      ocaml-top

      # :lang cc
      #clang
      #clang-tools
      # :lang data
      libxml2 # xmllint
      # :lang go
      #go
      gomodifytags
      gotests
      gore
      # :lang javascript
      #nodejs
      # :lang latex requires texlive (defined somewhere else)
      # :lang markdown
      go-grip
      #pandoc
      discount
      # :lang python
      black
      pipenv
      python3Packages.pyflakes
      python3Packages.isort
      python3Packages.pytest
      python3Packages.nose2
      # :lang org (texlive +...)
      gnuplot
      sqlite # +roam2
      # :lang plantuml
      #plantuml
      #graphviz
      #jdk
      # :lang rust
      #rustc
      #cargo
      #rust-analyzer
      # :lang sh
      #shfmt
      #shellcheck
      nodePackages.bash-language-server
      # :lang yaml
      nodePackages.yaml-language-server
      # :lang web
      nodePackages.js-beautify
      stylelint
      html-tidy
      # :lang zig
      #zig
      zls

      binutils
      zstd

      # :checkers grammar
      languagetool
      # :cherkers spell
      (aspellWithDicts (
        ds: with ds; [
          ar
          en
          en-computers
          en-science
        ]
      ))

      # lookup
      #python3

      # lsp
      nodePackages.typescript-language-server
      nodePackages.vscode-langservers-extracted

    ]);
  };
}
