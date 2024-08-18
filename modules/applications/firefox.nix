{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.applications;
  extension = name: {
    installation_mode = "force_installed";
    install_url = "https://addons.mozilla.org/firefox/downloads/latest/${name}/latest.xpi";
  };
in
{
  options.sifr.applications.firefox.enable = lib.mkOption {
    description = "Enables firefox configurations";
    type = lib.types.bool;
    default = config.sifr.graphics.apps;
  };
  config = lib.mkIf cfg.firefox.enable {
    environment.variables.BROWSER = "firefox";

    programs.firefox = {
      enable = true;
      package = pkgs.firefox-esr;
      languagePacks = [
        "en-GB"
        "ar"
      ];
      policies = {
        DisablePocket = true;
        DisableTelemetry = true;
        DisableFirefoxAccounts = true;
        DisableFirefoxStudies = true;
        DisableFirefoxScreenshots = true;
        DisablePrivateBrowsing = true;
        DontCheckDefaultBrowser = true;
        DisableSetDesktopBackground = true;
        NoDefaultBookmarks = true;
        OfferToSaveLogins = false;
        PasswordManagerEnabled = false;
        PictureInPicture = {
          Enabled = false;
          Locked = true;
        };
        FirefoxHome = {
          Pocket = false;
          Snippets = false;
        };
        UserMessaging = {
          WhatsNew = false;
          FeatureRecommendations = false;
          ExtensionRecommendations = false;
          SkipOnboarding = true;
        };
        SearchEngines = {
          Default = "DuckDuckGo";
        };
        EnableTrackingProtection = {
          Value = true;
          Locked = true;
          Cryptomining = true;
          Fingerprinting = true;
        };
        EncryptedMediaExtensions = {
          Enabled = false;
          Locked = true;
        };
        ExtensionSettings = {
          # Block all except listed
          "*".installation_mode = "blocked";
          # Extension IDs are found in "about:support"
          "jid1-BoFifL9Vbdl2zQ@jetpack" = extension "decentraleyes";
          "jid1-MnnxcxisBPnSXQ@jetpack" = extension "privacy-badger17";
          "savepage-we@DW-dev" = extension "save-page-we";
          "sponsorBlocker@ajay.app" = extension "sponsor-block";
          "uBlock0@raymondhill.net" = extension "ublock-origin";
          "{74145f27-f039-47ce-a470-a662b129930a}" = extension "clearurls";
          "{9063c2e9-e07c-4c2c-9646-cfe7ca8d0498}" = extension "old-reddit-redirect";
          # This was removed from extension store
          # "{d133e097-46d9-4ecc-9903-fa6a722a6e0e}" = extension "bypass-paywalls-clean";
        };
        Preferences = {
          "browser.aboutConfig.showWarning" = false;
          # Preferences
          "browser.newtabpage.enabled" = false; # Blank new page tab
          "browser.startup.homepage" = "https://start.duckduckgo.com";
          "browser.urlbar.placeholderName" = "DuckDuckGo";
          "browser.search.defaultenginename" = "DuckDuckGo";
          "signon.rememberSignons" = false; # we use a separate password manager
          "browser.formfill.enable" = false;
          "findbar.highlightAll" = true;

          # Fonts
          "font.name.monospace.x-western" = "Fira Code";
          "font.name.sans-serif.x-western" = "Inter";
          "font.name.serif.x-western" = "Merriweather";
          "font.name.sans-serif.ar" = "Noto Sans Arabic";
          "font.name.serif.ar" = "Amiri";

          # Only connect to HTTPS websites on all windows
          "dom.security.https_only_mode" = true;
          "dom.security.https_only_mode_ever_enabled" = true;

          # disable pocket (this seems to not work)
          "extensions.pocket.enable" = false;
          "browser.pocket.enable" = false;

          # Disable sponsored results in search bar
          "browser.urlbar.suggest.quicksuggest.nonsponsored" = false;
          "browser.urlbar.suggest.quicksuggest.sponsored" = false;

          # Don't recommend me features or extensions
          "browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features" = false;
          "browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons" = false;

          # Toolbar
          "browser.uiCustomization.state" = ''{"placements":{"widget-overflow-fixed-list":["jid1-bofifl9vbdl2zq_jetpack-browser-action","jid1-mnnxcxisbpnsxq_jetpack-browser-action","savepage-we_dw-dev-browser-action","_74145f27-f039-47ce-a470-a662b129930a_-browser-action","sponsorblocker_ajay_app-browser-action","_d133e097-46d9-4ecc-9903-fa6a722a6e0e_-browser-action"],"nav-bar":["back-button","forward-button","stop-reload-button","customizableui-special-spring1","urlbar-container","customizableui-special-spring2","downloads-button","fxa-toolbar-menu-button","ublock0_raymondhill_net-browser-action","_a4c4eda4-fb84-4a84-b4a1-f7c1cbf2a1ad_-browser-action","keepassxc-browser_keepassxc_org-browser-action"],"toolbar-menubar":["menubar-items"],"TabsToolbar":["tabbrowser-tabs","new-tab-button","alltabs-button"],"PersonalToolbar":["personal-bookmarks"]},"seen":["save-to-pocket-button","developer-button","ublock0_raymondhill_net-browser-action","_d133e097-46d9-4ecc-9903-fa6a722a6e0e_-browser-action","_74145f27-f039-47ce-a470-a662b129930a_-browser-action","jid1-bofifl9vbdl2zq_jetpack-browser-action","jid1-mnnxcxisbpnsxq_jetpack-browser-action","_a4c4eda4-fb84-4a84-b4a1-f7c1cbf2a1ad_-browser-action","savepage-we_dw-dev-browser-action","sponsorblocker_ajay_app-browser-action","keepassxc-browser_keepassxc_org-browser-action"],"dirtyAreaCache":["nav-bar","PersonalToolbar","toolbar-menubar","TabsToolbar","widget-overflow-fixed-list"],"currentVersion":17,"newElementCount":4}'';

          # Enable strict tracking protection
          "privacy.trackingprotection.enabled" = true;
          "privacy.trackingprotection.fingerprinting.enabled" = true;
          "privacy.trackingprotection.socialtracking.enabled" = true;
          "privacy.trackingprotection.pbmode.enabled" = true;
          "privacy.trackingprotection.cryptomining.enabled" = true;

          # The rest is from https://github.com/pyllyukko/user.js/blob/master/user.js

          # Disable telemetry, there are way too many settings to do something
          # this simple...
          "datareporting.healthreport.uploadEnabled" = false;
          "datareporting.healthreport.service.enabled" = false;
          "datareporting.healthreport.dataSubmissionEnabled" = false;
          "app.normandy.enabled" = false;
          "toolkit.telemetry.enabled" = false;
          "toolkit.telemetry.unified" = false;
          "toolkit.telemetry.archive.enabled" = false;
          "breakpad.reportURL" = "";
          "browser.aboutHomeSnippets.updateUrl" = "";
          "media.gmp-gmpopenh264.enabled" = false;
          "browser.tabs.crashReporting.sendReport" = false;
          "browser.crashReports.unsubmittedCheck.enabled" = false;
          "browser.startup.homepage_override.mstone" = "ignore";
          # Experiments and stuff
          "experiments.supported" = false;
          "experiments.enabled" = false;
          "extensions.shield-recipe-client.enabled" = false;
          "app.shield.optoutstudies.enabled" = false;
          "network.allow-experiments" = false;
          "browser.discovery.enabled" = false;
          "security.ssl.errorReporting.automatic" = false;

          # Hardening & anti-fingerprinting stuff
          # We don't want to set too many "anti-fingerprinting" settings
          # as that would make our browser unique, which defeats the purpose.
          "privacy.resistFingerprinting" = true;
          "privacy.resistFingerprinting.block_mozAddonManager" = true;
          "browser.fixup.alternate.enabled" = false;
          "browser.urlbar.trimURLs" = false;
          "network.dns.disablePrefetch" = true;
          "network.prefetch-next" = false;
          "network.http.speculative-parallel-limit" = 0;
          #"dom.enable_user_timing" = false;
          #"dom.mozTCPSocket.enabled" = false;
          "dom.network.enabled" = false;
          "dom.battery.enabled" = false;
          "beacon.enabled" = false;
          #"dom.event.clipboardevents.enabled" = false;
          "device.sensors.enabled" = false;
          "browser.send_pings" = false;
          #"dom.gamepad.enabled" = false;
          "browser.search.contryCode" = "US";
          "browser.search.region" = "US";
          "browser.search.geoip.url" = "";
          "intl.accept_languages" = "en-US, en";
          "intl.locale.matchOS" = false;
          "clipboard.autocopy" = false;
          "general.buildID.override" = "20100101";
          "browser.startup.homepage_override.buildID" = "20100101";
          "browser.uitour.enabled" = false;
          "network.security.esni.enabled" = true;
        };
      };
    };
  };
}
