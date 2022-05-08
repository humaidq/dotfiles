with import <nixpkgs> { };

rustPlatform.buildRustPackage rec {
  pname = "hstatus";
  version = "0.1";

 #src = /home/humaid/repos/public/hstatus;
  src = builtins.fetchGit {
    url = "https://git.sr.ht/~humaid/hstatus";
    rev = "e06f64a1c6e650644a5009f8b84b587c12af3b7a";
  };


  cargoSha256 = "sha256:186v7d3c2sv8rc1s7rz0sfzbc2wj7l7sxlcnpcz25gb5ni86gh1f";
  buildInputs = [ x11 xorg.libX11 ];
  nativeBuildInputs = [ rustc cargo pkg-config ];


  meta = with lib; {
    description = "modular status bar for dwm";
    homepage = "https://huma.id/projects/hstatus/";
    license = licenses.bsd2;
    mainProgram = "hstatus";
  };
}
