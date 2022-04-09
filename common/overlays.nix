self: super: {
  tor-browser-bundle-bin = super.tor-browser-bundle-bin.override {
    src = fetchurl {
      url = "https://huma.id/tor-browser-linux64-11.0.6_en-US.tar.xz";
      sha256 = "dfb1d238e2bf19002f2f141178c3af80775dd8d5d83b53b0ab86910ec4a1830d";
    };
  };
  dwm = super.dwm.override {
    src = fetchGit {
      url = "https://git.sr.ht/~humaid/dwm";
      rev = "f2943ca1b20fb5069d5383380f9a98a66eb466aa";
    };
  };
}
