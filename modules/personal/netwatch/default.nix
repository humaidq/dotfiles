{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.personal.netwatch;

  # doCheck = false: these scripts keep their own `#!/usr/bin/env python3`
  # shebang (unlike other writePython3Bin callers in this repo) so they stay
  # directly runnable during development; writePython3Bin prepends its own
  # interpreter line, which pushes that shebang to line 2 and makes flake8's
  # build-time check fail with E265 on every one of them. The programs are
  # already covered by their own test_*.py suites, so the lint gate is
  # redundant here.
  analyse = pkgs.writers.writePython3Bin "analyse" { doCheck = false; } (
    builtins.readFile ./analyse.py
  );
  store = pkgs.writers.writePython3Bin "store" { doCheck = false; } (builtins.readFile ./store.py);
  report = pkgs.writers.writePython3Bin "report" { doCheck = false; } (builtins.readFile ./report.py);
  seed = pkgs.writers.writePython3Bin "seed" { doCheck = false; } (builtins.readFile ./seed.py);

  netwatch = pkgs.writeShellApplication {
    name = "netwatch";
    runtimeInputs = [
      analyse
      report
      seed
      store
    ]
    ++ (with pkgs; [
      coreutils
      findutils
      openssh
      wireshark-cli
    ]);
    text = builtins.readFile ./netwatch.bash;
  };
in
{
  options.sifr.personal.netwatch.enable =
    lib.mkEnableOption "periodic LAN capture and local traffic analysis";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ netwatch ];
  };
}
