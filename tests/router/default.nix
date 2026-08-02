{ pkgs }:

{
  router-core = pkgs.testers.runNixOSTest ./core.nix;
}
