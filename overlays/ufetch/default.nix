{ pkgs, fetchFromGitLab }:

pkgs.stdenvNoCC.mkDerivation {
  pname = "ufetch";
  version = "git-2024-11-03";

  src = fetchFromGitLab {
    owner = "jschx";
    repo = "ufetch";
    rev = "19a71dc84e46377fafccde4acb8f27d224a4a360";
    hash = "sha256-VEiCUC9xrTJK4QIOHJv4eXartTqirn9erhyzmVRghGE=";
  };

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    install -Dm755 "$src/ufetch-nixos" "$out/bin/ufetch"
  '';

  postInstall = ''
    wrapProgram "$out/bin/ufetch" \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.nix ]}
  '';
}
