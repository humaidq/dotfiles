{ buildGoModule }:

buildGoModule {
  pname = "router-web";
  version = "0.1.0";

  src = ./.;

  # The uplink history is a real SQLite database rather than a format of our
  # own, so that the evidence for a support ticket can be assembled with the
  # sqlite3 CLI over SSH instead of through a query tool that would have to be
  # written first. That costs this module its only dependency and, with the
  # cgo bindings, a C compiler at build time — which is free here because these
  # routers are x86-64 and are built natively.
  vendorHash = "sha256-3dgQuKem9baSLR2vJ30zeZ/X7Rgg8kP5m5r7A1dVDYM=";

  postInstall = ''
    install -Dm644 ${./index.html} "$out/share/router-web/index.html"
    install -Dm644 ${./peers.html} "$out/share/router-web/peers.html"
    install -Dm644 ${./peers-index.html} "$out/share/router-web/peers-index.html"
    install -Dm644 ${./uplink.html} "$out/share/router-web/uplink.html"
    install -Dm644 ${./vpn.html} "$out/share/router-web/vpn.html"
    # The nav strip every page invokes. style.css is NOT here: it is embedded in
    # the binary, so a page can never render unstyled because an install dropped
    # a file — see serveStylesheet.
    install -Dm644 ${./nav.html} "$out/share/router-web/nav.html"
  '';
}
