# moshi-hook is distributed as a prebuilt static Go binary only (no public
# source); this repackages the goreleaser tarball used by getmoshi.app/install.sh.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  sources = {
    x86_64-linux = {
      arch = "x86_64";
      hash = "sha256-Q8sdb63ROezWZbGs08KoJ1u6+s45LQmo4EtynNfKyes=";
    };
    aarch64-linux = {
      arch = "arm64";
      hash = "sha256-64/F3E6GxRVeDJ1IhhoCHoWq/8nmefX56S60aUe2Te4=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "moshi-hook: unsupported system ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "moshi-hook";
  version = "0.2.66";

  src = fetchurl {
    url = "https://cdn.getmoshi.app/hook/v${finalAttrs.version}/moshi-hook_Linux_${source.arch}.tar.gz";
    inherit (source) hash;
  };

  # Tarball has no top-level directory.
  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 moshi-hook $out/bin/moshi-hook
    ln -s moshi-hook $out/bin/moshi
    mkdir -p $out/share/doc/moshi-hook
    cp -r README.md docs $out/share/doc/moshi-hook/
    runHook postInstall
  '';

  meta = {
    description = "Daemon and CLI that bridges AI coding agents to the Moshi mobile app";
    homepage = "https://getmoshi.app";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "moshi-hook";
  };
})
