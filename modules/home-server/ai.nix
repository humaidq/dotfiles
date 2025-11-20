{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sifr.home-server;
in
{
  config = lib.mkIf cfg.enable {
    services.ollama = {
      enable = true;
      user = "ollama";
      acceleration = "cuda";
      host = "0.0.0.0";
      package = pkgs.unstable.ollama-cuda;
      # loadModels = [
      #   "gemma2"
      #   "falcon2"
    };
    services.ollama.environmentVariables.OLLAMA_ORIGINS = "https://ai.alq.ae";

    services.open-webui = {
      package = pkgs.unstable.open-webui;
      enable = true;
      port = 2343;
    };
  };
}
