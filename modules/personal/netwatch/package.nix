# The netwatch command, shared by the NixOS module and the flake's packages
# output so `nix run` and the installed system get the same derivation.
{ pkgs }:
let
  py = name: pkgs.writers.writePython3Bin name { } (builtins.readFile (./. + "/${name}.py"));
in
pkgs.writeShellApplication {
  name = "netwatch";
  runtimeInputs =
    (map py [
      "analyse"
      "certcheck"
      "report"
      "seed"
      "store"
    ])
    ++ (with pkgs; [
      coreutils
      findutils
      openssh
      openssl
      wireshark-cli
    ]);
  text = builtins.readFile ./netwatch.bash;
}
