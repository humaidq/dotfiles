{
  lib,
  stdenvNoCC,
  src,
}:

# TX-02 Berkeley Mono is a commercial typeface; the OTFs come from a private
# build of our own licensed package, pinned as the berkeley-font flake input.
stdenvNoCC.mkDerivation {
  pname = "berkeley-mono";
  version = "2.004";

  inherit src;

  installPhase = ''
    runHook preInstall

    install -Dm644 *.otf -t "$out/share/fonts/opentype"

    runHook postInstall
  '';

  meta = {
    description = "TX-02 Berkeley Mono typeface family";
    homepage = "https://usgraphics.com/products/berkeley-mono";
    license = lib.licenses.unfree;
    platforms = lib.platforms.all;
  };
}
