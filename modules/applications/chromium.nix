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
    home-manager.users."${vars.user}" = {
      programs.chromium = {
        enable = true;
        package = pkgs.ungoogled-chromium;
        commandLineArgs = [
          # ungoogled-chromium flags
          "--extension-mime-request-handling=always-prompt-for-install"
          "--no-default-browser-check"
          "--bookmark-bar-ntp"
          "--custom-ntp=https://kagi.com"
          "--close-confirmation"
          "--disable-search-engine-collection"
          "--fingerprinting-canvas-image-data-noise"
          "--fingerprinting-canvas-measuretext-noise"
          "--fingerprinting-client-rects-noise"

          "--ozone-platform=wayland"
        ];
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

            (createChromiumExtension {
              id = "cjpalhdlnbpafiamejdnhcphjbkeiagm";
              sha256 = "sha256:06k70762vh79ak1d2gsrx9faadzj0gjqa4yz9x7vk9m7k85jp69p";
              version = "1.59.0";
            })

            (createChromiumExtension {
              id = "nngceckbapebfimnlniiiahkandclblb";
              sha256 = "sha256:1czz7iyi08msg9nj7yx1s9v2mdiiqd8mk2rp7w378y8wy8axr00g";
              version = "2024.9.0";
            })

            (createChromiumExtension {
              id = "cdglnehniifkbagbbombnjghhcihifij";
              sha256 = "sha256:1dyrb1jzj770jnv20fp8d5y42gr9880jydlhzzymprqwa1in5zkw";
              version = "1.2.1";
            })
          ];
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
