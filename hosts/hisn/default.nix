# The public-facing VPS: `duisk` and `lighthouse` folded into one host, moved
# in-country. Both were the same machine in everything but name — identical
# module stack, identical role layer — and splitting them only bought a second
# 1GB instance to keep patched.
#
# The overlay address is 10.10.0.20 — a new one, not either of the addresses
# it replaces. Inheriting lighthouse's 10.10.0.10 would have put two hosts on
# one certificate address, which splits a mesh rather than migrating it. A
# separate address let this host sit on the network as an ordinary client,
# reachable and testable, before it took on the lighthouse role, and it is why
# 10.10.0.10 can keep answering until every node has been rebuilt.
#
# Now a lighthouse, so it no longer queries for peers — nebula will not start
# with am_lighthouse set and lighthouse.hosts non-empty, and the module honours
# that. It learns endpoints from the nodes that register with it, which means a
# host not yet rebuilt against the two-lighthouse list in nebula.nix is one
# this machine cannot initiate to. It reaches oreamnos for every proxied vhost,
# so that host is the one to roll first.
#
# The certificate is signed under the name `hisn`, which is what nebula
# firewall rules elsewhere match on — see the rules on oreamnos, which name
# this host explicitly to let its reverse proxy through.
{
  self,
  inputs,
  config,
  ...
}:
{
  imports = [
    self.nixosModules.sifrOS.base
    self.nixosModules.sifrOS.personal.base
    self.nixosModules.sifrOS.security
    self.nixosModules.sifrOS.server
    inputs.disko.nixosModules.disko
    (import ./disk.nix)
    (import ./hardware.nix)
    (import ./webserver.nix)
    (import ./metrics.nix)
  ];
  networking.hostName = "hisn";

  # No `device` here: disko derives it from the EF02 partition in disk.nix and
  # writes boot.loader.grub.devices itself. Setting both is not redundant but
  # an error — the two definitions merge into a list with /dev/vda twice, and
  # the grub module rejects that as duplicated mirroredBoots.
  boot.loader.grub.enable = true;

  # Nebula keys
  sops.secrets."nebula/crt" = {
    sopsFile = ../../secrets/hisn.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  sops.secrets."nebula/key" = {
    sopsFile = ../../secrets/hisn.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };
  # Carried over from lighthouse rather than dropped with the rest of that
  # host. Nebula's built-in sshd listens on the overlay only and does not
  # depend on the system's sshd being reachable, which is the difference
  # between a diagnosable box and a reinstall when a bad nftables or nginx
  # change locks the real one out. That mattered less when this host was two
  # machines and one could be used to look at the other.
  sops.secrets."nebula/ssh_host_key" = {
    sopsFile = ../../secrets/hisn.yaml;
    owner = "nebula-sifr0";
    mode = "600";
  };

  sifr = {
    autoupgrade.enable = true;
    basePlus.enable = true;
    personal = {
      net = {
        sifr0 = true;
        isLighthouse = true;
        # Required, not stylistic: this host serves cache.huma.id and the rest
        # of vars.homeServerDomains itself. Mapping those names to oreamnos in
        # /etc/hosts the way an internal node does would point the machine at
        # the far end of its own reverse proxy, and would break the ACME
        # self-checks for every one of them.
        cacheOverPublic = true;
        node-crt = config.sops.secrets."nebula/crt".path;
        node-key = config.sops.secrets."nebula/key".path;
        ssh-host-key = config.sops.secrets."nebula/ssh_host_key".path;
      };
      o11y.client.enable = true;
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";
}
