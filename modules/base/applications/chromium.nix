{
  config,
  lib,
  pkgs,
  vars,
  inputs,
  ...
}:

let
  cfg = config.sifr.applications;
  helium = inputs.helium.packages.${pkgs.system}.default;
in
{

  options.sifr.applications.chromium.enable = lib.mkOption {
    description = "Enables chromium configurations";
    type = lib.types.bool;
    default = false;
  };
  config = lib.mkIf cfg.chromium.enable {
    environment.variables.BROWSER = "helium";

    environment.systemPackages = [
      pkgs.chromium
      helium
    ];

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

    home-manager.users."${vars.user}" = {
      programs.chromium = {
        enable = true;
        package = pkgs.chromium;
        commandLineArgs = [
          "--extension-mime-request-handling=always-prompt-for-install"
          "--no-default-browser-check"
          "--bookmark-bar-ntp"
          "--close-confirmation"
          "--disable-search-engine-collection"
          "--fingerprinting-canvas-image-data-noise"
          "--fingerprinting-canvas-measuretext-noise"
          "--fingerprinting-client-rects-noise"

          "--ozone-platform=wayland"
        ];
      };
    };
  };
}
