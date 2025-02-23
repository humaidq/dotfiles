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

  options.sifr.applications.chromium.enable = lib.mkOption {
    description = "Enables chromium configurations";
    type = lib.types.bool;
    default = config.sifr.graphics.apps;
  };
  config = lib.mkIf cfg.chromium.enable {
    environment.systemPackages = [ pkgs.ungoogled-chromium ];
    home-manager.users."${vars.user}" = {
      programs.chromium = {
        enable = true;
        package = pkgs.ungoogled-chromium;
        commandLineArgs = [
          # ungoogled-chromium flags
          "--extension-mime-request-handling=always-prompt-for-install"
          "--no-default-browser-check"
          "--bookmark-bar-ntp"
          "--custom-ntp=https://alq.ae"
          "--close-confirmation"
          "--disable-search-engine-collection"
          "--fingerprinting-canvas-image-data-noise"
          "--fingerprinting-canvas-measuretext-noise"
          "--fingerprinting-client-rects-noise"

          "--ozone-platform=wayland"
        ];
        /*
          extensions =
            let
              createChromiumExtensionFor =
                browserVersion:
                {
                  id,
                  sha256,
                  version,
                }:
                {
                  inherit id;
                  crxPath = builtins.fetchurl {
                    url = "https://clients2.google.com/service/update2/crx?response=redirect&acceptformat=crx2,crx3&prodversion=${browserVersion}&x=id%3D${id}%26installsource%3Dondemand%26uc";
                    name = "${id}.crx";
                    inherit sha256;
                  };
                  inherit version;
                };
              createChromiumExtension = createChromiumExtensionFor (
                lib.versions.major pkgs.ungoogled-chromium.version
              );
            in
            [
              # Last bump: 2024-09-14

              {
                # chromium web store
                id = "ocaahdebbfolfmndjeplogmgcagdmblk";
                crxPath = builtins.fetchurl {
                  name = "chromium-web-store.crx";
                  url = "https://github.com/NeverDecaf/chromium-web-store/releases/download/v1.5.4.3/Chromium.Web.Store.crx";
                  sha256 = "sha256:1j3ppn6j0aaqwyj5dyl8hdmjxia66dz1b4xn69h1ybpiz6p1r840";
                };
                version = "1.5.4.3";
              }

              # uBlock Origin
              (createChromiumExtension {
                id = "cjpalhdlnbpafiamejdnhcphjbkeiagm";
                sha256 = "sha256:0lj0b5a2vga9x8nr12f9ijv1n0f8zcyzml19bzvw722jb98mic88";
                version = "1.59.0";
              })

              # Bitwarden
              (createChromiumExtension {
                id = "nngceckbapebfimnlniiiahkandclblb";
                sha256 = "sha256:0kxkjnac3h1vcjjn8x5c1dpplp3hk1wi1j53qa7h2yyf21yns92h";
                version = "2024.9.0";
              })
            ];
        */
      };
    };
    #programs.chromium = {
    #  enable = true;
    #  extraOpts = {
    #    DefaultSearchProviderEnabled = true;
    #    DefaultSearchProviderSearchURL = "https://duckduckgo.com/?q={searchTerms}";
    #  };
    #};
  };
}
