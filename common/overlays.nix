{ pkgs, config, lib, ... }:
let
  overlayFunction = final: prev: {
    gnome = prev.gnome.overrideScope' (finalGnome: prevGnome: {
      gdm =
        let
          logo-override = builtins.toFile "logo-override" ''
            [org.gnome.login-screen]
            logo='${./assets/hsys-icon-blue.png}'
          '';
        in
        prevGnome.gdm.overrideAttrs (old: {
          preInstall = ''
            install -D ${logo-override} \
              $out/share/glib-2.0/schemas/org.gnome.login-screen.gschema.override
          '';
        });
      });
    tor-browser-bundle-bin = prev.tor-browser-bundle-bin.override {
      src = lib.fetchurl {
        url = "https://huma.id/tor-browser-linux64-11.0.6_en-US.tar.xz";
        sha256 = "dfb1d238e2bf19002f2f141178c3af80775dd8d5d83b53b0ab86910ec4a1830d";
      };
    };
  };

in {
  config = {
    nixpkgs.overlays = [ overlayFunction ];
  };
}
