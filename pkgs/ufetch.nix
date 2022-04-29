with import <nixpkgs> { };

stdenv.mkDerivation {
  pname = "ufetch";
  version = "21f22c2f";
  src = fetchGit {
    url = "https://gitlab.com/jschx/ufetch";
    ref = "master";
    rev = "21f22c2f08475b0c6466b8839bebcae0d63295ce";
  };
  buildInputs = [ bash ];
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    mkdir -p $out/bin
    cp ufetch-nixos $out/bin/ufetch
    wrapProgram $out/bin/ufetch \
      --prefix PATH : ${lib.makeBinPath [ bash ]}
  '';
}
