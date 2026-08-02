{ lib, pkgs }:

lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (import ./router { inherit pkgs; })
