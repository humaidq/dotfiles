{ buildGoModule }:

buildGoModule {
  pname = "router-web";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;

  postInstall = ''
    install -Dm644 ${./index.html} "$out/share/router-web/index.html"
  '';
}
