{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.sifr.personal.research.enable = lib.mkEnableOption "research tools";

  config = lib.mkIf config.sifr.personal.research.enable {
    environment.systemPackages = with pkgs; [
      zotero
      texliveFull
      tectonic
      typst
      typstyle
      typst-live
    ];
  };
}
