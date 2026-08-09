# not a stable interface, do not reference outside the codex package but make a copy if you need
#
# codex's code-mode-runtime pulls in the v8 crate with `v8_enable_sandbox`,
# which implies pointer compression. denoland/rusty_v8 publishes no prebuilt
# for that feature combination, so upstream builds its own and attaches it to a
# `rusty-v8-v${version}` release on openai/codex — see
# .github/actions/setup-rusty-v8, which feeds the same two files into
# RUSTY_V8_ARCHIVE and RUSTY_V8_SRC_BINDING_PATH.
{
  lib,
  stdenv,
  fetchurl,
}:

{
  fetchRustyV8 =
    args:
    let
      profile = "ptrcomp_sandbox_release";
      target = stdenv.hostPlatform.rust.rustcTarget;
      baseUrl = "https://github.com/openai/codex/releases/download/rusty-v8-v${args.version}";
    in
    {
      archive = fetchurl {
        name = "librusty_v8-${args.version}";
        url = "${baseUrl}/librusty_v8_${profile}_${target}.a.gz";
        sha256 = args.archiveShas.${stdenv.hostPlatform.system};
        meta = {
          inherit (args) version;
          sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
        };
      };

      # Bindgen output matching the archive above; generating it locally would
      # mean a full V8 source build, so it is fetched alongside.
      srcBinding = fetchurl {
        name = "rusty_v8-src-binding-${args.version}.rs";
        url = "${baseUrl}/src_binding_${profile}_${target}.rs";
        sha256 = args.srcBindingShas.${stdenv.hostPlatform.system};
        meta = {
          inherit (args) version;
        };
      };
    };
}
