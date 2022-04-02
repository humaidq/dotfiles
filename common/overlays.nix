self: super: {
  tor-browser-bundle-bin = super.tor-browser-bundle-bin.override {
    src = fetchurl {
      url = "https://huma.id/tor-browser-linux64-11.0.6_en-US.tar.xz";
      sha256 = "dfb1d238e2bf19002f2f141178c3af80775dd8d5d83b53b0ab86910ec4a1830d";
    };
  };
}
