{ lib, fetchFromGitHub, rustPlatform }:

rustPlatform.buildRustPackage rec {
  pname = "hstatus";
  version = "0.1";

  src = /home/humaid/repos/public/hstatus;

  cargoSha256 = "sha256-LAow4DVqON5vrYBU8v8wzg/HcHxm1GqS9DMre3y12Jo=";
  nativeBuildInputs = [ xorg.libX11 ];


  meta = with lib; {
    description = "modular status bar for dwm";
    homepage = "https://huma.id/projects/hstatus/";
    license = licenses.bsd2;
    mainProgram = "hstatus";
  };
}

