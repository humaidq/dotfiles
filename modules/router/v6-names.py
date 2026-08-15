"""Name IPv6 clients in the DNS log.

blocky resolves a client address to a device name by asking dnsmasq for its
PTR, and dnsmasq answers from its DHCP leases. That covers every IPv4 client
and no IPv6 one, because nothing here hands out an IPv6 address: the router
advertises a prefix and each device configures itself. So an IPv6 query is
logged as `client_names=fe80::10e7:2429:3f27:5c78`, and every Grafana panel
that groups by client shows a column of raw addresses nobody can attribute.

The join that fixes it is the MAC. The kernel's neighbour table has the
device's IPv6 addresses against its MAC, the lease file has its IPv4 address
and its name against the same MAC, and this writes the result where dnsmasq
will serve it as a PTR.

Only link-local addresses are written, and that is not a simplification. A
client sending to the router's link-local — which is what the RA advertises as
the resolver — must source the packet from its own link-local, so fe80:: is
where every IPv6 query on this network actually comes from. Global addresses
would also need their reverse zone routed to dnsmasq, and that zone changes
with every prefix delegation, which is to say every redial.
"""

import ipaddress
import os
import sys

# fe80::/10 in practice means fe80::/64: every stack that autoconfigures uses
# the /64, and the reverse zone routed to dnsmasq is 8.e.f.ip6.arpa, which is
# fe80::/16. An address outside that would be written here and then never
# looked up, so it is skipped rather than silently useless.
LINK_LOCAL = ipaddress.ip_network("fe80::/16")


def read_leases(text):
    """Return {mac: name} from the dnsmasq lease file.

    Fields are "<expiry> <mac> <address> <name> <clientid>". A lease with no
    name carries "*", which is dnsmasq's way of saying the client never sent
    one; those devices stay unnamed here rather than being given their address
    as a name, which is what the log already shows and would be no improvement.
    """
    names = {}
    for line in text.split("\n"):
        parts = line.split()
        if len(parts) < 4:
            continue
        mac, name = parts[1].lower(), parts[3]
        if name == "*":
            continue
        names[mac] = name
    return names


def read_neighbours(text):
    """Return [(address, mac)] from `ip -6 neigh show` output.

    Entries with no lladdr — FAILED, INCOMPLETE — have no MAC to join on and
    are skipped. The MAC is found by name rather than by position because the
    fields after the address vary: a router entry carries an extra "router"
    word before its state.
    """
    found = []
    for line in text.split("\n"):
        fields = line.split()
        if not fields:
            continue
        try:
            addr = ipaddress.ip_address(fields[0])
        except ValueError:
            continue
        if addr.version != 6:
            continue
        mac = ""
        for index, field in enumerate(fields):
            if field == "lladdr" and index + 1 < len(fields):
                mac = fields[index + 1].lower()
                break
        if not mac:
            continue
        found.append((addr, mac))
    return found


def build(neigh_text, lease_text, domain):
    """Render the hosts file.

    Sorted, so an unchanged network produces a byte-identical file and the
    caller can skip telling dnsmasq to re-read it. Without that this would
    signal dnsmasq every time the timer fired.
    """
    names = read_leases(lease_text)
    lines = []
    for addr, mac in read_neighbours(neigh_text):
        if addr not in LINK_LOCAL:
            continue
        name = names.get(mac)
        if not name:
            continue
        lines.append("{}\t{}.{}".format(addr, name, domain))
    return "\n".join(sorted(set(lines)))


def main(argv):
    if len(argv) != 5:
        sys.stderr.write(
            "usage: v6-names NEIGH_OUTPUT LEASES DOMAIN OUT\n"
            "writes a dnsmasq addn-hosts file mapping link-local addresses to"
            " DHCP names\n"
        )
        return 2
    neigh_path, lease_path, domain, out_path = argv[1:]
    with open(neigh_path) as handle:
        neigh_text = handle.read()
    try:
        with open(lease_path) as handle:
            lease_text = handle.read()
    except FileNotFoundError:
        # No leases yet is a real state at boot, and an empty file is the
        # correct output for it — every name here comes from a lease.
        lease_text = ""

    rendered = build(neigh_text, lease_text, domain)
    if rendered:
        rendered += "\n"

    try:
        with open(out_path) as handle:
            if handle.read() == rendered:
                # Unchanged. Exit 1 so the unit can skip the reload without
                # this having to know how dnsmasq is signalled.
                return 1
    except FileNotFoundError:
        pass

    # Written and renamed rather than truncated in place: dnsmasq may be
    # reading this file, and a half-written hosts file is a set of devices that
    # silently lose their names until the next run.
    tmp = out_path + ".tmp"
    with open(tmp, "w") as handle:
        handle.write(rendered)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
