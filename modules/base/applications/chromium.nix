{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sifr.applications;
in
{

  options.sifr.applications.chromium.enable = lib.mkOption {
    description = "Enables chromium configurations";
    type = lib.types.bool;
    default = false;
  };
  config = lib.mkIf cfg.chromium.enable {
    environment.variables.BROWSER = "helium";

    environment.systemPackages = [ pkgs.helium ];

    # Helium reads managed policy from the upstream chromium path
    # (/etc/chromium/policies), so this file applies to it unchanged.
    environment.etc."chromium/policies/managed/vanilla.json".text = builtins.toJSON {
      DefaultBrowserSettingEnabled = false;
      BookmarkBarEnabled = false;
      BrowserSignin = 0;

      #SearchSuggestEnabled = false;
      #AlternateErrorPagesEnabled = false;
      PasswordManagerEnabled = false;

      #DefaultSearchProviderEnabled = true;
      #DefaultSearchProviderName = "Google";
      #DefaultSearchProviderSearchURL = "https://www.google.com/search?q={searchTerms}";
      #DefaultSearchProviderSuggestURL = "https://www.google.com/complete/search?output=chrome&q={searchTerms}";
      #DefaultSearchProviderAlternateURLS = [
      #  "https://search.nixos.org/packages?channel=unstable&query={searchTerms}"
      #];

      #ExtensionInstallForcelist = [
      #  # "cjpalhdlnbpafiamejdnhcphjbkeiagm" # ublock origin
      #  "bgnkhhnnamicmpeenaelnjfhikgbkllg" # adguard
      #  "fnaicdffflnofjppbagibeoednhnbjhg" # floccus
      #  "nngceckbapebfimnlniiiahkandclblb" # bitwarden
      #  "ekhagklcjbdpajgpjgmbionohlpdbjgc" # zotero connector
      #];
    };
  };
}
