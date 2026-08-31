{
  config,
  lib,
  ...
}:
let
  cfg = config.sifr.router;

  # The LAN as a network address, derived from sifr.router.lanAddress: whole
  # octets of the router's own address for as much of the prefix as it covers,
  # zeros for the rest. dns.nix already asserts the prefix is /8, /16 or /24,
  # which is what makes the octet-wise form exact — and chrony wants the
  # network address, not the host one, so the trailing octets have to go.
  lanPrefix = lib.toInt (lib.elemAt (lib.splitString "/" cfg.lanAddress) 1);
  lanOctets = lib.splitString "." (lib.head (lib.splitString "/" cfg.lanAddress));
  lanNetwork =
    lib.concatStringsSep "." (
      lib.take (lanPrefix / 8) lanOctets ++ lib.genList (_: "0") (4 - lanPrefix / 8)
    )
    + "/${toString lanPrefix}";
in
{
  config = lib.mkIf cfg.enable {
    # chrony is already on every host in this flake (personal/networking/time.nix),
    # but only as a client: without an `allow` it never opens the server port, so
    # the 123 hole in the LAN firewall led nowhere. This is what turns it into a
    # server, the same way oreamnos does it.
    #
    # A no-op if chrony is absent, and the DHCP option below would then point at
    # a port nothing answers — which is worse than not advertising at all, since
    # a client that takes the option stops asking the pool. Caught here instead.
    assertions = [
      {
        assertion = config.services.chrony.enable;
        message = ''
          sifr.router serves NTP on ${lib.head (lib.splitString "/" cfg.lanAddress)} and hands
          itself out as the NTP server over DHCP, which needs services.chrony
          enabled. sifrOS.personal.base enables it.
        '';
      }
    ];

    # LAN only. The WAN side is a PPPoE link facing the ISP and has no business
    # answering time queries — an open NTP server on a public address is an
    # amplification reflector — and the firewall only opens 123 on lan0 anyway.
    #
    # IPv4 only, deliberately. Clients on this LAN take the server from DHCP
    # option 42 (dns.nix), which is v4; there is no DHCPv6 server here, and a
    # router advertisement cannot carry an NTP server at all. The delegated v6
    # prefix also rotates on every daily redial, so there is no stable v6
    # network to name here even if something wanted it.
    services.chrony.extraConfig = lib.mkAfter ''
      allow ${lanNetwork}
    '';
  };
}
