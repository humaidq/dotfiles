{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.profiles;
in
{
  options.sifr.profiles = {
    research = lib.mkEnableOption "research profile";
  };
  config = lib.mkIf cfg.research {
    environment.systemPackages = with pkgs; [
      # Reference management
      zotero

      # Document processing
      texliveFull
      tectonic
      typst
      typst-fmt
      typst-live
    ];
  };

}
