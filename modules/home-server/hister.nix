{
  config,
  lib,
  ...
}:

let
  cfg = config.sifr.home-server;
in
{
  # The module and the package both landed in 26.05, so this used to import
  # nixos/modules/services/web-apps/hister.nix straight out of the unstable
  # input and pin `package = pkgs.unstable.hister`. Both are gone now: the
  # stable module is declared for us and would collide with a second copy of
  # the same file, and `package` can fall back to its mkPackageOption default.
  config = lib.mkIf cfg.enable {
    # A single shared access token, injected as HISTER__APP__ACCESS_TOKEN
    # rather than written into settings, because everything under `settings`
    # is rendered to a world-readable file in the store.
    #
    # Without it hister has no authentication whatsoever — `authMode` is
    # "none" unless either app.access_token or app.user_handling is set, and
    # every route, including the ones that delete history, is then open to
    # anything that can reach the vhost. Being on an internal name is not a
    # substitute for that.
    sops.secrets."hister/env" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "hister";
      mode = "600";
    };

    services.hister = {
      enable = true;
      environmentFile = config.sops.secrets."hister/env".path;

      # dataDir is deliberately left at its default so the unit gets a plain
      # StateDirectory=hister, i.e. /var/lib/hister owned by hister:hister at
      # 0750. That path is persisted from hosts/oreamnos/default.nix; it holds
      # the SQLite index and .secret_key and nothing reconstructs either.
      #
      # `port` is left unset too. It exists only to override the port half of
      # server.address via HISTER_PORT and to drive openFirewall, and neither
      # is wanted here — nginx is the only thing that talks to this.
      settings = {
        app.title = "hister.alq.ae";

        server = {
          address = "127.0.0.1:4433";

          # Not cosmetic. The search endpoint compares the browser's Origin
          # header against base_url and answers 500 on any mismatch, and when
          # base_url is unset hister derives it from the listen address —
          # http://127.0.0.1:4433 — so the scheme alone is enough to fail the
          # check. The symptom is a page that loads normally with a search box
          # that returns nothing. It also decides the links in the RSS feeds
          # and the self-exclusion rule that stops hister indexing its own
          # pages.
          base_url = "https://hister.alq.ae";
        };
      };
    };
  };
}
