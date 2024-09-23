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
      package = pkgs.ollama;
      # loadModels = [
      #   "gemma2"
      #   "falcon2"
    };
    services.ollama.environmentVariables.OLLAMA_ORIGINS = "https://ai.alq.ae";

    services.open-webui = {
      enable = true;
      port = 2343;
    };
    #services.nextjs-ollama-llm-ui = {
    #  enable = true;
    #  port = 2343;
    #  ollamaUrl = "https://ollama.alq.ae";
    #};
  };
}
