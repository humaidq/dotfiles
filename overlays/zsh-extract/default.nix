{ stdenvNoCC, fetchFromGitHub }:

stdenvNoCC.mkDerivation {
  pname = "zsh-extract";
  version = "git-2019-12-13";

  src = fetchFromGitHub {
    owner = "le0me55i";
    repo = "zsh-extract";
    rev = "ecad02d5dbd9468e0f77181c4e0786cdcd6127a9";
    hash = "sha256-XG9cJuQHAodyd7BrgryC/MiPV1Ch9jK6TvAN+y13uwI=";
  };

  installPhase = ''
    runHook preInstall

    install -Dm644 "$src/extract.plugin.zsh" "$out/share/zsh/plugins/zsh-extract/extract.plugin.zsh"
    install -Dm644 "$src/_extract" "$out/share/zsh/site-functions/_extract"

    runHook postInstall
  '';
}
