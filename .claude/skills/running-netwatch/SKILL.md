---
name: running-netwatch
description: Use when running netwatch to sample a device's traffic, when reading a netwatch report, or when querying its history to find an endpoint that keeps changing address
---

# Running netwatch

## Overview

netwatch samples traffic for watched devices on the router, analyses it on this
laptop, appends a dated report, and accumulates a queryable history.

It reports evidence and never conclusions. "Top peer holds 100% of bytes on UDP
4500" is what it says; deciding whether that is a VPN, and whether that VPN is
allowed, is yours. Nothing in it classifies a domain, because classifying an
arbitrary new domain is judgement and any pattern encoding it would only match
what was already known.

## Before the first run

**Open one SSH master.** netwatch never opens one — the router key is on a
hardware token, an unattended run cannot produce a tap, and a script that
silently prompted would hang forever. It checks for the socket and skips loudly
if it is missing.

```bash
ssh -M -o ControlMaster=yes -o ControlPersist=168h -fN <router>   # one tap
ssh -O check <router>                                             # confirm
```

**Write the watchlist** to `netwatch/devices.conf`, one device per line, MAC
first. That file, the reports, the captures and the store are all git-ignored —
this repository is public and none of it belongs in git.

```
<mac>  <label>
<mac>  <label>
```

MAC rather than IP, deliberately: a DHCP lease gets reused, and IP-keyed history
silently merges two devices into one.

## Running it

```bash
NETWATCH_DIR=$PWD/netwatch \
NETWATCH_HOST=<router> \
nix run .#netwatch
```

| Variable | Default | Worth changing when |
|---|---|---|
| `NETWATCH_HOST` | none, required | always |
| `NETWATCH_DIR` | `$PWD/netwatch` | always set it explicitly — the default follows your shell's cwd |
| `NETWATCH_IFACE` | `enp2s0` | the router's LAN interface is named something else |
| `NETWATCH_SECS` | `300` | a shorter window for a quick look; a tunnel shows up in minutes of real use |
| `NETWATCH_JOURNAL_SINCE` | `2 days ago` | widen it on a first run, when the accumulated files are empty and the window is all the history there is |
| `NETWATCH_KEEP_PCAP_DAYS` | `3` | captures hold other people's traffic in the clear; shorter is better |
| `NETWATCH_KEEP_ROWS_DAYS` | `120` | the store's rows hold no payload, so they are kept far longer than the captures — that split is deliberate |

A run takes the capture window plus roughly ten seconds.

## Reading the report

`netwatch/reports/YYYY-MM-DD.txt`, appended per run.

**The first run on a fresh install is noise.** The baseline is empty, so every
domain in the window reads as new — expect a thousand lines of
`new_domain_network` and ignore them. The baseline is written after the analysis,
so the second run is the first meaningful one.

Per device: total bytes, peer count, ranked observations, then top peers with
byte shares.

| Observation | What it means |
|---|---|
| `top_peer_share` | One peer holds most of the device's bytes. The tunnel signature — ordinary use spreads across many peers with the largest well under half. |
| `vpn_port` | UDP 500/4500 (IPsec), 1194, 51820, or GRE/ESP. Nothing ordinary on a phone uses these. |
| `unexplained_peer` | Real volume to an address no resolver lookup explains — an endpoint the app carries hardcoded. |
| `new_domain_network` | Nothing here has ever resolved it. The deterministic stand-in for an operator rotating to a fresh domain. |
| `new_domain_device` | This device started reaching something the household already used. Weaker. |
| `non_ipv4_not_analysed` | A coverage note, not a finding. It counts ARP as well as IPv6, so it is not evidence of IPv6 use. |

A peer line ending `no-dns` is one nothing explains. Those are the ones worth a
certificate check, which runs automatically and appends below the peers.

`RUN SKIPPED: <reason>` means the run did not happen. An empty report that
skipped is not an empty report that found nothing — that distinction is the
whole reason the line exists.

## Finding something that keeps changing address

This is what the store is for, and what a single report cannot show. An operator
renting a fresh address per session leaves no repeated address, so history keyed
on the address shows unrelated peers. Grouped by the network that owns them, the
same data shows a count of distinct addresses inside one range.

```bash
sqlite3 netwatch/store.db "
  SELECT net24, COUNT(DISTINCT ip) AS addrs, COUNT(*) AS sightings
  FROM peer_obs WHERE explained = 0
  GROUP BY net24 ORDER BY addrs DESC LIMIT 20;"
```

Others worth having:

```sql
-- ranges first seen recently, versus ones that have always been there
SELECT net24, MIN(run_ts), MAX(run_ts), COUNT(DISTINCT ip)
FROM peer_obs GROUP BY net24 ORDER BY MIN(run_ts) DESC LIMIT 20;

-- addresses seen exactly once: a fresh address per session looks like this
SELECT ip, net24, MAX(run_ts) FROM peer_obs
GROUP BY ip HAVING COUNT(*) = 1 ORDER BY MAX(run_ts) DESC;

-- any name ever observed against a range, which is how an otherwise
-- anonymous range gets identified: operators rotate addresses far more
-- often than they rotate a certificate or an SNI
SELECT DISTINCT net24, sni, resolved_name FROM peer_obs
WHERE net24 = '<range>' AND (sni != '' OR resolved_name != '');

-- did it actually run, or has it been skipping?
SELECT datetime(run_ts,'unixepoch'), captured, skip_reason
FROM runs ORDER BY run_ts DESC LIMIT 10;
```

## Common mistakes

- **Reading a first run as a finding.** Everything is new when the baseline is
  empty. Look at the second run.
- **Treating a quiet device as a clean one.** `0 bytes across 0 peers` means the
  device was asleep during the window, not that it did nothing all day.
- **Concluding from one observation.** A dominant peer is also what a video call
  looks like. Confirm with the DNS gap and the port or certificate before acting.
- **Blocking on a certificate flag alone.** Ordinary apps do serve hand-made
  certificates — a pinned client has no use for a public CA. Check whether a
  device known to run the app also reaches the endpoint before blocking anything.
  See [[detecting-client-tunnels]] for that test.
- **Letting the SSH master lapse and not noticing.** Every run then skips. Check
  the `runs` table if reports go quiet.
- **Quoting the report anywhere public.** It is a record of what people in the
  house did. It does not go in a commit message, a blocklist comment, or this
  repository.
