{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.applications;
  emacs =
    with pkgs;
    ((emacsPackagesFor emacs29-pgtk).emacsWithPackages (
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
    services.languagetool.enable = true;

    environment.systemPackages =
      [
        emacs
      ]
      ++ (with pkgs; [

        (aspellWithDicts (
          ds: with ds; [
            ar
            en
            # Dead packages?
            #en-computers
            #en-science
          ]
        ))

        # lookup & org-roam
        sqlite

        # treemacs
        python3

        # copilot
        nodejs

      ]);
  };
}
