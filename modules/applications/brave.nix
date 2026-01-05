{
  config,
  lib,
  pkgs,
  vars,
  ...
}:

let
  cfg = config.sifr.applications;
in
{

  options.sifr.applications.brave.enable = lib.mkOption {
    description = "Enables brave configurations";
    type = lib.types.bool;
    default = false;
  };
  config = lib.mkIf cfg.brave.enable {
    environment.systemPackages = [ pkgs.brave ];

    environment.etc."brave/policies/managed/vanilla.json".text = builtins.toJSON {
      DefaultBrowserSettingEnabled = false;
      BookmarkBarEnabled = false;
      BrowserSignin = 0;

      SearchSuggestEnabled = false;
      AlternateErrorPagesEnabled = false;
      PasswordManagerEnabled = false;

      BraveRewardsDisabled = true;
      BraveWalletDisabled = true;
      BraveVPNDisabled = true;
      BraveAIChatEnabled = false;
      BraveNewsDisabled = true;
      BraveWebDiscoveryEnabled = false;
      BraveAdsDisabled = true;
      TorDisabled = true;
      BraveTalkDisabled = true;
      BraveSpeedreaderEnabled = false;
      BraveP3AEnabled = false;
      BraveStatsPingEnabled = false;
      SyncDisabled = true;

      DefaultSearchProviderEnabled = true;
      DefaultSearchProviderName = "Google";
      DefaultSearchProviderSearchURL = "https://www.google.com/search?q={searchTerms}";
      DefaultSearchProviderSuggestURL = "https://www.google.com/complete/search?output=chrome&q={searchTerms}";
      DefaultSearchProviderAlternateURLS = [
        "https://search.nixos.org/packages?channel=unstable&query={searchTerms}"
      ];

      ExtensionInstallForcelist = [
        "cjpalhdlnbpafiamejdnhcphjbkeiagm" # ublock origin
        "fnaicdffflnofjppbagibeoednhnbjhg" # floccus
        "nngceckbapebfimnlniiiahkandclblb" # bitwarden
        "ekhagklcjbdpajgpjgmbionohlpdbjgc" # zotero connector
      ];
    };

    home-manager.users."${vars.user}" = {
      programs.chromium = {
        enable = true;
        package = pkgs.brave;
        commandLineArgs = [
          # ungoogled-chromium flags
          "--extension-mime-request-handling=always-prompt-for-install"
          "--no-default-browser-check"

          "--ozone-platform=wayland"
        ];
      };
    };
  };
}
