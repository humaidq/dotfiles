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

    services.mysql = {
      enable = true;
      package = pkgs.mariadb;
      ensureDatabases = [ "matomo" ];
      # No password anywhere, including in the installer: ensureUsers creates
      # this one IDENTIFIED WITH unix_socket, so only the `matomo` unix user —
      # which is the phpfpm pool user and the user the console runs as — can
      # authenticate as it, and only over the local socket. The installer is
      # given the socket path as the database host and an empty password field.
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
  #    page use `/run/mysqld/mysqld.sock` as the server, `matomo` as both user
  #    and database name, and leave the password blank.
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
  #    without the second, every visit is attributed to one address.
  #
  # 3. In Administration > System > General Settings, turn off "Archive reports
  #    when viewed from the browser" — the timer above does it.
  #
  # Matomo will warn that the JavaScript tracker is not writable. It is in the
  # store; that warning is expected and harmless.
}
