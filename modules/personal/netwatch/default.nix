{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.personal.netwatch;

  analyse = pkgs.writers.writePython3Bin "analyse" { } (builtins.readFile ./analyse.py);
  store = pkgs.writers.writePython3Bin "store" { } (builtins.readFile ./store.py);
  report = pkgs.writers.writePython3Bin "report" { } (builtins.readFile ./report.py);
  seed = pkgs.writers.writePython3Bin "seed" { } (builtins.readFile ./seed.py);
  certcheck = pkgs.writers.writePython3Bin "certcheck" { } (builtins.readFile ./certcheck.py);

  netwatch = pkgs.writeShellApplication {
    name = "netwatch";
    runtimeInputs = [
      analyse
      certcheck
      report
      seed
      store
    ]
    ++ (with pkgs; [
      coreutils
      findutils
      openssh
      openssl
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
