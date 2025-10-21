{
  pkgs,
  fetchFromGitLab,
}:

let
  src = fetchFromGitLab {
    owner = "jschx";
    repo = "ufetch";
    rev = "19a71dc84e46377fafccde4acb8f27d224a4a360";
    hash = "sha256-VEiCUC9xrTJK4QIOHJv4eXartTqirn9erhyzmVRghGE=";
  };
  raw = pkgs.writeShellScriptBin "ufetch" (builtins.readFile "${src}/ufetch-nixos");
in

pkgs.symlinkJoin {
  name = "ufetch";
  paths = [ raw ];
  buildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram "$out/bin/ufetch" \
      --prefix PATH : ${
        pkgs.lib.makeBinPath [
          pkgs.nix
        ]
      }
  '';
}
