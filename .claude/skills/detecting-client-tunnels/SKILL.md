---
name: detecting-client-tunnels
description: Use when checking whether a device on the home network is running a VPN, proxy, or tunnel, when a client appears to be bypassing router filtering, or when asked to watch one LAN device's traffic from the router
---

# Detecting client tunnels

## Overview

Domain and keyword lists do not find tunnels. Anyone who set one up
deliberately is not resolving `nordvpn.com` — they are pointed at a rented VPS
by bare IP, or at a self-hosted endpoint whose name was resolved once, weeks
ago, and cached in the app config.

**Find tunnels by flow shape, not by name.** A normal phone talks to hundreds
of remote addresses across dozens of networks, in short bursts, each preceded
by a DNS lookup that matches the destination. A tunnelled phone sends
essentially everything to one address, for hours, with no DNS lookups that
explain it. That contrast is the whole detection.

## Prerequisites

Packet capture and conntrack both need root on the router. Confirm before
starting:

```bash
ssh <router> 'sudo -n true && echo ok'
```

If that fails, stop and get passwordless sudo for `tcpdump` deployed first — a
capture that needs an interactive password cannot run unattended.

## Use one SSH socket

Where the SSH key lives on a hardware token, **every new connection costs a
physical touch**, and the person who asked for the monitoring is usually away
from the keyboard while it runs. Open one multiplexed master while they are
still present, then reuse it for every later command:

```bash
ssh -M -o ControlMaster=yes -o ControlPersist=12h -fN <router>   # one touch
ssh -O check <router>                                            # confirm it is up
```

Every subsequent `ssh <router> '...'` rides that socket with no touch, as long
as the host argument is spelled identically — `ControlPath` is keyed on
user@host:port, so `user@host` and `host` are different sockets and cost two
touches. Set `ControlPersist` longer than the capture will run.

Never open a second master, and never open one per command.

## Steps

### 1. Resolve the device to an address

```bash
ssh <router> 'ip neigh | grep -i <mac>; grep -i <mac> /var/lib/dnsmasq/dnsmasq.leases'
```

The lease also gives the client hostname, which is worth having for the report.
Re-check the address at the end of a long capture — DHCP may have moved it.

### 2. Capture the client's egress

**Capture full payload on the first pass.** A capture costs however long the
person actually uses the device, and it cannot be re-run retroactively — if the
snaplen was truncated, the SNI that would have named the endpoint is gone and
the whole window has to be repeated. Take everything the first time:

```bash
ssh <router> 'nohup sudo -n tcpdump -i <lan-iface> -nn -s 0 -G 1800 -W 1 \
  -w /tmp/client.pcap host <client-ip> and not port 53 >/dev/null 2>&1 &'
```

`-s 0` keeps the TLS ClientHello intact, so byte ranking (step 3), SNI
extraction and protocol checks all come out of this one file. Never start with
a small snaplen meaning to "get SNI later" — later is a second capture and a
second wait.

`-G 1800 -W 1` makes tcpdump exit by itself after 30 minutes, which matters
because a NOPASSWD rule scoped to tcpdump cannot `sudo pkill` the root process
it started. `nohup ... &` detaches it so the SSH session can drop.

An hour of ordinary phone use is enough to see the shape; a tunnel shows up in
minutes of active use. Exclude port 53 so DNS chatter does not distort the byte
totals — DNS gets read separately in step 4.

### 3. Rank remote addresses by bytes

This is the measurement that matters:

```bash
ssh <router> 'sudo tcpdump -nn -q -r /tmp/client.pcap 2>/dev/null' \
  | awk -v c=<client-ip> '
      { split($3,s,"."); split($5,d,".");
        sip=s[1]"."s[2]"."s[3]"."s[4]; dip=d[1]"."d[2]"."d[3]"."d[4];
        peer = (sip==c) ? dip : sip;
        n=split($0,f,": "); b=f[n]+0; bytes[peer]+=b; pkts[peer]++ }
      END { for (p in bytes) printf "%12d %8d  %s\n", bytes[p], pkts[p], p }' \
  | sort -rn | head -20
```

Read the top of that list:

| Shape | Reading |
|---|---|
| Top peer holds a large share of all bytes, sustained over the whole capture | Tunnel. This is the signature. |
| Top peers are many, each modest, from different networks | Normal. CDNs and app backends. |
| One peer, high volume, on UDP 443 or a random high port | Tunnel — WireGuard, QUIC-shaped proxy, or similar. |
| IP protocol 47 or 50 (`ip proto 47 or 50`) present at all | Tunnel — GRE/ESP. Nothing else on a phone uses these. |
| One peer that only carries traffic while the device is otherwise idle | Push/keepalive, not a tunnel. Check the byte total, not the flow count. |

Volume alone is not enough — a video stream is also one-peer-heavy. What
separates a tunnel is that the single peer carries traffic of *every* kind at
once, and the device makes few or no other outbound connections while it is up.

### 4. Confirm no DNS explains the top peer

```bash
ssh <router> 'journalctl -u blocky --since "2 hours ago" --no-pager' \
  | grep "client_ip=<client-ip> " | grep -F '<top-peer-ip>'
```

Nothing back means the address was never resolved during the capture window —
it is hardcoded in a config. That is a strong tunnel indicator. A normal
high-volume peer will always have a matching lookup.

### 5. Inspect the endpoint's certificate

Self-hosted tunnel endpoints are given certificates by hand, and the giveaway
is the validity period — nobody renewing by hand issues for a year:

```bash
ssh <router> 'echo | openssl s_client -connect <top-peer-ip>:443 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates'
```

| Certificate | Reading |
|---|---|
| Validity span over ~2 years | Forged. The CA/B limit was 39 months before 2020 and 398 days after; no public CA has ever issued a 10- or 100-year cert. |
| `issuer` identical to `subject` | Self-signed. Same conclusion. |
| Subject is an IP, a random string, or a placeholder like `example.com` | Tunnel endpoint. |
| Public CA, ≤ 398 days, subject matches a real service | Ordinary TLS. Not your tunnel. |
| Connection refused / no TLS on 443 | Try the port actually seen in step 3, or it is a raw protocol — go back to protocol numbers. |

A named issuer is not proof of a real cert — the issuer string is just text, and
tunnel endpoints copy a well-known CA's to look ordinary. Three cheap checks
break the disguise, and any one of them is conclusive:

```bash
openssl x509 -noout -serial -dates -subject -issuer   # from the s_client output above
whois <cert-subject-domain> | grep -i creation        # when was the name registered?
```

- **Serial.** Public CAs have been required to use long random serials since
  2016. A short hand-assigned one (`serial=1003`) was not issued by a CA.
- **`notBefore` earlier than the domain's registration date.** No CA can
  validate control of a name that did not exist yet. Impossible for a real cert.
- **Subject domain with no A record.** A cert for a name that resolves nowhere
  is not protecting a real service.

Also check who owns the address (`whois <ip>`). A hosting provider —
DigitalOcean, Hetzner, Vultr, OVH, Contabo — carrying the bulk of a phone's
traffic is not a CDN. A phone has no reason to talk to a rented VPS.

### 5a. Attribute the endpoint before blocking it

A forged cert on a rented VPS is suggestive, not sufficient. Ordinary apps do
serve hand-made certificates — pinned clients do not need a public CA, so a
copied issuer string and an absurd validity can mean a lazy vendor rather than
a tunnel. VoIP backends look especially tunnel-shaped: relay and allocation
servers on cheap hosting, reached by hardcoded IP, carrying steady traffic.

The cheap decisive test is **a device you control that is known to run the
app**. Ask which clients ever queried the domain:

```bash
journalctl -u <resolver> --no-pager | grep -E "question_name=[a-z0-9.-]*<domain>" \
  | grep -oP "client_names=\K[^ ]+" | sort | uniq -c | sort -rn
```

If your own phone — which you know has the legitimate app and no tunnel — is in
that list, the domain belongs to the app. If only the device under suspicion
ever asks for it, that is the red flag. One query settles what certificate
forensics only hints at.

Do this before writing any block. Blocking a VoIP provider's relay fleet breaks
calling for everyone in the house, and the failure looks nothing like a
blocklist problem.

### 6. Clean up

```bash
ssh <router> 'sudo pkill -f "tcpdump.*<client-ip>"; sudo rm -f /tmp/client.pcap'
ssh -O exit <router>
```

A capture file of someone's traffic should not be left on the router.

## Common mistakes

- **Grepping DNS logs for VPN brand names.** Finds only people using a
  commercial app with default settings, which is not who you are looking for.
  Start from flow shape.
- **Judging by flow count instead of bytes.** A tunnel is one flow. Sorting by
  connection count buries it under normal browsing.
- **Capturing on the WAN interface.** After NAT the client address is gone.
  Capture on the LAN interface, filtered to the client.
- **Including port 53.** DNS is high-count, low-byte, and always points at the
  router — it crowds the top of a packet-count ranking and tells you nothing.
- **Treating one big peer as proof.** Confirm with the DNS gap (step 4) and the
  certificate or protocol (step 5) before reporting.
- **Reconnecting per command.** Each one is another hardware-key touch, and it
  will strand the run if nobody is at the keyboard.
