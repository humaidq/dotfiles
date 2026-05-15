{ stdenvNoCC, fetchFromGitHub }:

stdenvNoCC.mkDerivation {
  pname = "ls-colors";
  version = "git-2025-06-06";

  src = fetchFromGitHub {
    owner = "trapd00r";
    repo = "LS_COLORS";
    rev = "810ce8cac886ac50e75d84fb438b549a1f9478ee";
    hash = "sha256-MMzNknuELhpSkvcPgCL2Pp5A6DZrLajkz8qLphSNbjY=";
  };

  installPhase = ''
    runHook preInstall

    install -Dm644 "$src/LS_COLORS" "$out/share/ls-colors/LS_COLORS"
    install -Dm644 "$src/lscolors.sh" "$out/share/ls-colors/lscolors.sh"
    install -Dm644 "$src/lscolors.csh" "$out/share/ls-colors/lscolors.csh"

    runHook postInstall
  '';
}
