# Matomo: self-hosted web analytics for the public sites, reachable at
# m.huma.id.
#
# This is the only thing on this host that wants MySQL — everything else here
# is on postgres — but Matomo supports no other backend, so MariaDB comes along
# with it. Nothing else should be pointed at it.
#
# Matomo has no declarative setup: the schema, the admin account and
# config.ini.php are all created by a browser-based installer on first visit,
# and config.ini.php stays mutable state under the data directory afterwards.
# So the parts that cannot be expressed here are written down in the install
# notes at the bottom of this file rather than silently left to be discovered.
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
    services.matomo = {
      enable = true;
      hostname = "m.huma.id";

      # Public access comes in through hisn, which reverse proxies this name
      # over the overlay and speaks plain HTTP to port 80 here.
      #
      # addSSL, not forceSSL: a forced redirect would answer hisn with
      # 301 https://m.huma.id, and that name resolves to hisn — the request
      # would come straight back. Keeping an HTTPS listener as well is not
      # decoration: internal hosts on the mesh get m.huma.id in /etc/hosts
      # pointing at this machine (it lands in vars.homeServerDomains by virtue
      # of being an nginx vhost here), and matomo-archive-processing.service
      # calls its own --url=https://m.huma.id every hour, so that path has to
      # work locally too. Both are step-ca certificates, which every host in
      # the fleet trusts via security.pki.certificateFiles.
      nginx = {
        enableACME = true;
        forceSSL = false;
        addSSL = true;
      };

      # Hourly archiving from the timer, rather than letting browser hits
      # trigger it. This is what makes it safe to turn off browser triggers and
      # to expire raw visitor logs in the Matomo UI.
      periodicArchiveProcessing = true;
    };

    # Report archiving is where Matomo actually needs memory — a plain tracking
    # request does not come close. 128M is both the PHP default and Matomo's
    # own minimum, which leaves no headroom at all on the one workload that
    # uses it.
    services.phpfpm.pools.matomo.phpOptions = ''
      memory_limit = 256M
    '';

    # Matomo parallelises archiving by forking `console climulti:request`
    # subprocesses, and it will only do so if CliMulti\Process::isSupported()
    # passes — which shells out to `ps wwx` and pipes it through `awk`, and
    # additionally wants to find its own pid in that output. Neither binary is
    # on the path of a systemd service or a php-fpm worker by default, so
    # without this the system check reports "Managing processes via CLI: not
    # supported" and archiving silently degrades to one sequential pass.
    #
    # Both ends need it. The php-fpm pool is what the system check page runs
    # under, and phpEnv is the way to get a variable past php-fpm's clear_env.
    # The timer is where archiving actually happens, and NixOS's default unit
    # path carries coreutils, findutils, grep and sed — but not procps or gawk.
    services.phpfpm.pools.matomo.phpEnv.PATH = lib.makeBinPath [
      pkgs.procps
      pkgs.gawk
      pkgs.coreutils
    ];
    systemd.services.matomo-archive-processing.path = [
      pkgs.procps
      pkgs.gawk
      pkgs.coreutils
    ];

    services.mysql = {
      enable = true;
      package = pkgs.mariadb;
      ensureDatabases = [ "matomo" ];
      # No password anywhere, including in the installer: ensureUsers creates
      # this one IDENTIFIED WITH unix_socket, so only the `matomo` unix user —
      # which is the phpfpm pool user and the user the console runs as — can
      # authenticate as it, and only over the local socket. The installer gets
      # `localhost` and an empty password field; see note 1 below for why that
      # reaches the socket rather than TCP.
      ensureUsers = [
        {
          name = "matomo";
          ensurePermissions = {
            "matomo.*" = "ALL PRIVILEGES";
          };
        }
      ];
    };

    # Alongside the postgres dumps, and for the same reason: the visit history
    # only exists here. Note this covers the database but not
    # /var/lib/matomo/config/config.ini.php, which holds the instance salt —
    # that lives on the persist dataset and comes back with the host.
    services.mysqlBackup = {
      enable = true;
      databases = [ "matomo" ];
      location = "/mnt/humaid/files/oreamnos/mysql-backup";
    };
  };

  # First-run notes, since none of this can be set from here:
  #
  # 1. Visit https://m.huma.id and work through the installer. On the database
  #    page:
  #
  #      Database Server  localhost      (the default — see below)
  #      Login            matomo
  #      Password         (blank)
  #      Database Name    matomo
  #      Table Prefix     matomo_        (the default)
  #      Adapter          PDO\MYSQL
  #      Database engine  MariaDB        (the form defaults to MySQL)
  #
  #    "Database engine" is not cosmetic. Matomo picks a schema class from it,
  #    and against a MariaDB server the MySQL one emits query time limits as a
  #    /*+ MAX_EXECUTION_TIME(n) */ hint, which MariaDB reads as a comment and
  #    ignores — so archiving queries run with no cap. It also gets the ranking
  #    query sort behaviour and the end-of-life check for 11.4 LTS wrong.
  #
  #    `localhost`, not the socket path, even though this authenticates over the
  #    socket. Matomo only converts a path into a PDO `unix_socket` when it
  #    appears in the *port* field (core/Db/Adapter.php), and the installer form
  #    has no port field — a path typed into Database Server ends up in the DSN
  #    as `host=` and fails to resolve. It works out anyway because nixpkgs
  #    builds PHP with pdo_mysql.default_socket and mysqli.default_socket
  #    already pointing at /run/mysqld/mysqld.sock, which is where the module
  #    below puts it, so `localhost` lands on the right socket by itself.
  #
  #    Do this from a host on the mesh, BEFORE the public m.huma.id DNS record
  #    exists. There is no way to seed the superuser account from here — Matomo
  #    has no console command for it, only the installer — so until the wizard
  #    has been completed, whoever reaches it first becomes the superuser. An
  #    internal host already resolves this name to this machine via
  #    /etc/hosts, so the install can be finished with nothing published.
  #
  #    The account itself lives in the database (matomo_user), not under
  #    /var/lib/matomo, so it is the mysqlBackup dumps that carry it. There is
  #    no CLI password reset either; recovery is Matomo's own reset mail, which
  #    works because this host has sendmail via msmtp. `twofactorauth:disable
  #    -2fa-for-user` and `login:unblock-blocked-ips` are the two console
  #    commands worth knowing for a lockout.
  #
  # 2. Matomo is behind hisn's proxy, so out of the box it sees hisn's overlay
  #    address as the client and plain HTTP as the scheme. Add to
  #    /var/lib/matomo/config/config.ini.php under [General]:
  #
  #      assume_secure_protocol = 1
  #      proxy_client_headers[] = HTTP_X_FORWARDED_FOR
  #      proxy_host_headers[] = HTTP_X_FORWARDED_HOST
  #
  #    Without the first, Matomo builds http:// URLs and drops secure cookies;
  #    without the second, every visit is attributed to one address. The first
  #    is also what clears the system check's "Forced SSL Connection" warning:
  #    the connection already is TLS, at hisn — Matomo simply cannot see it.
  #
  #    Do NOT set force_ssl = 1 before assume_secure_protocol = 1. On its own it
  #    is an infinite redirect: Matomo sees http, answers 302 to
  #    https://m.huma.id, hisn terminates that and proxies back over http, and
  #    Matomo redirects again. With assume_secure_protocol set it is redundant
  #    anyway, because nothing ever reaches Matomo as http in the first place.
  #
  # 3. In Administration > System > General Settings, turn off "Archive reports
  #    when viewed from the browser" — the timer above does it.
  #
  # Matomo will warn that the JavaScript tracker is not writable. It is in the
  # store; that warning is expected and harmless.
}
