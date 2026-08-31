# What this host is for is traffic it forwards or answers, and none of that is
# visible in node_exporter: a saturated CPU and a busy NIC look the same
# whether they come from one vhost being crawled or from every service working
# normally. This file adds the two views that distinguish them — nginx's own
# counters and a structured access log — and leaves the nebula side to
# modules/personal/networking/nebula.nix, which serves the whole mesh rather
# than this host.
#
# Everything here binds to loopback and is scraped by the Alloy client already
# running on this host. Nothing new is exposed to the WAN.
{ config, ... }:
let
  # Loopback only, and deliberately not 80: see the listen override below.
  statusPort = 8081;
in
{
  # stub_status, which is the only source for currently-open connections. The
  # access log can reconstruct request rates after the fact but knows nothing
  # about connections that are open and idle, which is exactly the shape a
  # slowloris or a stuck upstream takes.
  services.nginx.statusPage = true;

  # The NixOS default puts this vhost on 0.0.0.0:80 and relies on `deny all`
  # to keep it private. Two objections on a host like this one. It becomes the
  # first server block on port 80 and therefore the default for requests
  # arriving with an unmatched Host, which is a change in public behaviour for
  # two dozen named vhosts. And a loopback-only fix — 127.0.0.1:80 next to the
  # existing 0.0.0.0:80 — leaves nginx binding a specific address and a
  # wildcard on one port, which works but is a bind that has to succeed at
  # startup on a machine whose entire purpose is serving 80 and 443.
  #
  # Its own port avoids both. Nothing else is listening on it and no other
  # server block mentions it, so this cannot displace or contend with the
  # public listeners.
  services.nginx.virtualHosts.localhost.listen = [
    {
      addr = "127.0.0.1";
      port = statusPort;
    }
  ];

  services.prometheus.exporters.nginx = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9113;
    scrapeUri = "http://127.0.0.1:${toString statusPort}/nginx_status";
  };

  # A second access_log target rather than a replacement: the file under
  # /var/log/nginx stays as it is, still in the combined format and still
  # rotated by the nginx module's logrotate stanza, so anything already read
  # on the box keeps working. The JSON copy goes to the journal, which is
  # where Alloy already reads from — a file source would need a DynamicUser
  # service to be granted access to nginx's log directory for no gain.
  #
  # Both names are logged because they answer different questions and only one
  # of them is safe to promote to a Loki label. $host is what the client asked
  # for, which is what tells the dozen aliases on www.alq.ae apart — and it is
  # client-controlled, so anyone sending junk Host headers to the address could
  # mint unbounded label cardinality with it. $server_name is the server block
  # that actually matched, one of a fixed set, and is what the dashboard's
  # vhost picker is built from in modules/personal/o11y/client.nix.
  #
  # upstream_response_time is quoted because it is empty for anything served
  # locally, and an unquoted empty value makes the whole line invalid JSON —
  # which in Loki means the line silently disappears from every panel that
  # parses it, not that it shows up as an error.
  services.nginx.appendHttpConfig = ''
    log_format access_json escape=json '{'
      '"time":"$time_iso8601",'
      '"server":"$server_name",'
      '"vhost":"$host",'
      '"method":"$request_method",'
      '"uri":"$uri",'
      '"status":$status,'
      '"bytes":$body_bytes_sent,'
      '"duration":$request_time,'
      '"upstream_time":"$upstream_response_time",'
      '"upstream_status":"$upstream_status",'
      '"scheme":"$scheme",'
      '"proto":"$server_protocol",'
      '"tls":"$ssl_protocol",'
      '"remote":"$remote_addr",'
      '"referer":"$http_referer",'
      '"ua":"$http_user_agent",'
      '"request_id":"$request_id"'
    '}';

    access_log /var/log/nginx/access.log combined;
    access_log syslog:server=unix:/dev/log,tag=nginx,severity=info access_json;
  '';

  # journald drops messages past 10000 in 30s per service and notes the
  # suppression in a line of its own. For a unit that logs one line per
  # request that ceiling is reachable by a single crawler, and the resulting
  # gap looks identical to a traffic lull on every rate panel. The journal's
  # own SystemMaxUse cap is what bounds disk use here, not this limit.
  systemd.services.nginx.serviceConfig.LogRateLimitIntervalSec = 0;

  sifr.personal.o11y.client.extraConfig = ''
    prometheus.scrape "nginx" {
      targets = [{
        __address__ = "127.0.0.1:${toString config.services.prometheus.exporters.nginx.port}",
        instance    = "${config.networking.hostName}",
      }]
      scrape_interval = "30s"
      forward_to      = [prometheus.remote_write.default.receiver]
    }

  '';
}
