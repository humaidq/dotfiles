{
  config,
  lib,
  ...
}:
let
  cfg = config.sifr.router;

  # The router's filter lists. Each was a .txt beside this module until
  # 2026-09-03 and is now a sops binary secret in secrets/router/, decrypted to
  # /run/secrets at activation. Consumers take a path, not a store path.
  #
  # What that changed, since ip-blocklist.nix used to argue for the opposite: a
  # store path was expanded by a sandboxed derivation, so a malformed line
  # failed `nixos-rebuild`. A secret is unreadable at eval and build time, so
  # the parse happens when the loader unit starts instead. The generators still
  # exit non-zero on a bad line — the failure moved, it did not soften. Same
  # trade nft-lowtrust-macs made, for the same reason.
  #
  # Editing a list is now `sops` plus the restart named in `units`, with no
  # rebuild. A unit missing from that list is how an edit becomes a silent
  # no-op.
  #
  # mode: 0444 where the reader runs under DynamicUser and so has no uid to own
  # the file — blocky and router-web both do. These are secrets to keep them
  # out of a public repository, not out of the router's own filesystem; the
  # note on router/access-points in hosts/bongo/default.nix is the precedent.
  # 0400 everywhere else, where the reader is root.
  lists = {
    ipBlocklist = {
      file = "custom-ip-blocklist.txt";
      units = [ "nft-blocklists-local.service" ];
    };
    portBlocklist = {
      file = "custom-port-blocklist.txt";
      units = [
        "nft-blocklists-local.service"
        "router-web.service"
      ];
      mode = "0444";
    };
    throttle = {
      file = "custom-throttle-list.txt";
      units = [ "nft-blocklists-local.service" ];
    };
    vpnIntelThrottle = {
      file = "custom-vpn-intel-throttle.txt";
      units = [ "nft-blocklists-local.service" ];
    };
    imo = {
      file = "custom-imo-list.txt";
      units = [ "imo-policy.service" ];
    };
    lowtrustPorts = {
      file = "custom-lowtrust-ports.txt";
      units = [ "nft-blocklists-local.service" ];
    };
    lowtrustSubnets = {
      file = "custom-lowtrust-subnets.txt";
      units = [ "nft-blocklists-local.service" ];
    };
    lowtrustAllowSubnets = {
      file = "custom-lowtrust-allow-subnets.txt";
      units = [ "nft-blocklists-local.service" ];
    };
    lowtrustAsns = {
      file = "custom-lowtrust-asns.txt";
      units = [ "nft-blocklists-local.service" ];
    };
    cdnQuotaAsns = {
      file = "custom-cdn-quota-asns.txt";
      units = [ "nft-blocklists-local.service" ];
    };
    # The only ALLOW-list among the ASN files, and the only list here whose
    # sets live in a table other than router-blocklists — cooldown.nix owns
    # them. The restart unit is still nft-blocklists-local, because that unit
    # is the single writer for every list-to-set expansion regardless of which
    # table the set is in; see nftGens in ip-blocklist.nix.
    cooldownAllowAsns = {
      file = "custom-cooldown-allow-asns.txt";
      units = [ "nft-blocklists-local.service" ];
    };
    lowtrustStunHosts = {
      file = "custom-lowtrust-stun-hosts.txt";
      units = [ "nft-lowtrust-stun.service" ];
    };
    lowtrustAllowDomains = {
      file = "custom-lowtrust-allow-domains.txt";
      units = [ "nft-lowtrust-allow-domains.service" ];
    };
    dnsBlocklist = {
      file = "custom-blocklist.txt";
      units = [ "blocky.service" ];
      mode = "0444";
    };
    dnsWhitelist = {
      file = "custom-whitelist.txt";
      units = [ "blocky.service" ];
      mode = "0444";
    };
    # Written for the dns-review skill, and read on the router by the
    # dark-peer collector in web/darkpeer.go, which uses it to decide whether
    # the name behind a dominant peer is one that means anything. See
    # web/commondomains.go for why that question and not "does it have a name".
    #
    # 0444 like the blocky lists above and for the same reason: router-web runs
    # under DynamicUser and has no build-time uid to grant it to. The content
    # is a list of domains everyone here talks to constantly, which is the one
    # category in secrets/router carrying no per-person detail — it is
    # encrypted to travel with the lists it belongs to, not because reading it
    # would tell anyone anything.
    #
    # No restart unit. The collector re-reads the file when it changes, so a
    # rebuild that rewrites it is picked up without restarting the service and
    # dropping the connection-table baseline it judges against.
    dnsCommonDomains = {
      file = "dns-common-domains.txt";
      units = [ ];
      mode = "0444";
    };
    # Nothing reads this one; it is kept here so it is decrypted, backed up and
    # key-rotated with the lists it documents.
    inspectedApps = {
      file = "inspected-apps.txt";
      units = [ ];
    };
  };
in
{
  options.sifr.router.lists = lib.mapAttrs (
    name: _:
    lib.mkOption {
      type = lib.types.path;
      description = "Path to the ${name} list. Defaults to the decrypted secrets/router entry.";
    }
  ) lists;

  config = lib.mkIf cfg.enable {
    sops.secrets = lib.mapAttrs' (
      name: meta:
      lib.nameValuePair "router/lists/${name}" {
        sopsFile = ../../secrets/router/${meta.file};
        format = "binary";
        mode = meta.mode or "0400";
        restartUnits = meta.units;
      }
    ) lists;

    sifr.router.lists = lib.mapAttrs (name: _: config.sops.secrets."router/lists/${name}".path) lists;
  };
}
