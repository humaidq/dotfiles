{
  config,
  lib,
  ...
}:

let
  cfg = config.sifr.home-server;
in
{
  # `services.ntfy-sh`, not `services.ntfy` — there is no such module. nixpkgs
  # carries two unrelated projects that both call themselves ntfy: `pkgs.ntfy`
  # is dschep's Python CLI that raises a desktop notification when a long
  # command finishes, and `pkgs.ntfy-sh` is binwiederhier's pub/sub server,
  # which is this one. The suffix is the only thing telling them apart.
  config = lib.mkIf cfg.enable {
    # Accounts, their ACL entries and Grafana's publish token, injected as
    # NTFY_AUTH_USERS / NTFY_AUTH_ACCESS / NTFY_AUTH_TOKENS rather than written
    # into `settings`, every value of which is rendered to a world-readable
    # file in the store.
    #
    # Declarative provisioning is used in place of `ntfy user add` so the
    # account list is reviewable rather than living only in
    # /var/lib/ntfy-sh/user.db. ntfy flags these rows as provisioned, reapplies
    # them on every start, and refuses to let the web app edit or delete them.
    #
    # The formats, each of which ntfy validates and refuses to start on:
    #   NTFY_AUTH_USERS=name:bcrypt-hash:role     role is 'admin' or 'user'
    #   NTFY_AUTH_ACCESS=user:topic:permission    regular users only — an admin
    #                                             already has everything, and
    #                                             an ACL entry naming one is an
    #                                             error
    #   NTFY_AUTH_TOKENS=user:tk_...:label        token is ^tk_[-_A-Za-z0-9]{29}$
    # Each is a repeatable flag, so the entries are comma-separated when they
    # arrive through the environment. bcrypt hashes contain '$' but never a
    # comma, and systemd does no expansion on EnvironmentFile values, so
    # neither needs escaping.
    #
    # What is in there today: `humaid` as admin, and `grafana` as a regular
    # user holding a token and write-only on `alerts`. A new publisher —
    # groundwave, say — is a third user, its own topic in auth-access, and its
    # own token, so that one service losing its token never becomes permission
    # to publish somewhere else.
    sops.secrets."ntfy/env" = {
      sopsFile = ../../secrets/home-server.yaml;
      owner = "ntfy-sh";
      mode = "600";
    };

    # The upstream module sets DynamicUser, which makes systemd keep the
    # StateDirectory at /var/lib/private/ntfy-sh and leave a symlink behind at
    # /var/lib/ntfy-sh. That is incompatible with how this host persists state:
    # hosts/oreamnos/default.nix bind-mounts /var/lib/ntfy-sh from the persist
    # dataset, so systemd finds a real directory where it wanted its symlink,
    # tries to migrate it into /var/lib/private, and fails the rename with
    # EXDEV across the mount — the unit never gets as far as running ntfy.
    #
    # Turning it off rather than persisting /var/lib/private/ntfy-sh instead,
    # because the module already declares a static ntfy-sh user and group, so
    # nothing is gained by the dynamic allocation, and every other persisted
    # service on this host keeps its state at the obvious path. The rest of the
    # unit's hardening is untouched.
    systemd.services.ntfy-sh.serviceConfig = {
      DynamicUser = lib.mkForce false;
      Group = config.services.ntfy-sh.group;
      # systemd's StateDirectory default is 0755, which it reapplies on every
      # start and which therefore wins over the mode on the persist entry.
      # user.db holds the password hashes and the access tokens and ntfy
      # creates it 0644, so without this every service account on the host can
      # read it.
      StateDirectoryMode = "0700";
    };

    services.ntfy-sh = {
      enable = true;
      environmentFile = config.sops.secrets."ntfy/env".path;

      settings = {
        # Not cosmetic. Attachment download URLs, the links in the web app and
        # the server identity the Android app pins a subscription to are all
        # derived from this. Left unset it falls back to the listen address and
        # hands out http://127.0.0.1:2586 links that work nowhere but here.
        base-url = "https://ntfy.alq.ae";
        listen-http = "127.0.0.1:2586";

        # The default is read-write for anonymous visitors. On an internal name
        # that still means every device on the LAN can subscribe to any topic
        # it can guess, so nothing is readable or publishable without one of
        # the accounts above.
        auth-default-access = "deny-all";
        enable-signup = false;
        # The web app's login form and the Android app's "add user" flow both
        # post to /v1/account/token, which is disabled — and 404s — unless this
        # is on. It does not create accounts; enable-signup does, and stays off.
        enable-login = true;

        # ntfy loads named templates by filename out of a directory, so
        # ?template=grafana below resolves to grafana.yml in here.
        template-dir = "${./ntfy-templates}";

        # nginx is the only thing that ever connects, and the proxy headers in
        # web-server.nix deliberately blank X-Forwarded-For, so there is no
        # real client address to rate limit on: with behind-proxy left off
        # every request — the phone holding a subscription open and Grafana
        # firing a batch of alerts alike — shares the single 127.0.0.1 bucket,
        # and 60 requests in is where the subscriber starts getting 429s.
        # Authentication is the access control on this server; the rate limiter
        # is only in the way.
        visitor-request-limit-exempt-hosts = "127.0.0.1";

        # Longer than the 12h default because ntfy.alq.ae resolves to a
        # reachable address only on the LAN and on the mesh. A phone that
        # spends a weekend away reconnects and asks for everything since its
        # last message id; at 12h the alerts it missed are already gone from
        # the cache and it is never told they happened.
        cache-duration = "48h";

        # Alerts carry no attachments. This is a ceiling on how much of the
        # persisted dataset the attachment cache can take, not a target.
        attachment-total-size-limit = "1G";
      };
    };
  };
}
