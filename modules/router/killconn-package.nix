# The killconn tool, as a package expression rather than a NixOS module.
#
# It lives in its own file because two modules build it: tools.nix, which
# installs it and puts it on router-web's PATH, and cooldown.nix, which needs it
# on the `cooldown` tool's own PATH so that starting a cooldown can tear down
# the flows the device already has open. Two copies of a writeShellApplication
# call would evaluate to the same store path today and silently diverge the
# first time either grew an input.
{
  writeShellApplication,
  coreutils,
  gawk,
  conntrack-tools,
  iproute2,
  nftables,
}:

writeShellApplication {
  name = "killconn";
  runtimeInputs = [
    coreutils
    gawk
    conntrack-tools
    # For the neighbour lookup that folds a device's IPv4 and IPv6 addresses
    # together, and for arming the reset set. Neither is optional: without
    # iproute2 a dual-stack device loses half its flows, and without nftables a
    # TCP teardown silently degrades to deleting state nobody is told about.
    iproute2
    nftables
  ];
  text = builtins.readFile ./killconn.bash;
}
