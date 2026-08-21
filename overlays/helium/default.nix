# Helium, the ungoogled-chromium fork, comes from its upstream flake as a
# prebuilt tarball: a plain mkDerivation with no `override` argument. That
# means home-manager's programs.chromium cannot manage it (it calls
# `package.override { commandLineArgs = ...; }`, and derives its dotfile paths
# from the pname, which would land in ~/.config/chromium rather than
# ~/.config/net.imput.helium). Extra switches go through a wrapper instead.
{
  symlinkJoin,
  makeWrapper,
  unwrapped,
}:
symlinkJoin {
  name = "helium-${unwrapped.version}";
  paths = [ unwrapped ];
  nativeBuildInputs = [ makeWrapper ];

  postBuild = ''
    wrapProgram $out/bin/helium \
      --add-flags "--no-default-browser-check" \
      --add-flags "--extension-mime-request-handling=always-prompt-for-install"
  '';

  # The upstream wrapper already passes --ozone-platform-hint=auto, so Wayland
  # needs nothing here. The ungoogled fingerprinting-noise switches are gone in
  # Helium — it has its own `helium-noise*` preferences, set in the settings UI
  # rather than on the command line.

  inherit (unwrapped) meta;
}
