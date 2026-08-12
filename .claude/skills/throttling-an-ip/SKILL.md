---
name: throttling-an-ip
description: Use when someone hands over IP addresses to throttle or block on the router, when adding entries to modules/router/custom-throttle-list.txt or custom-ip-blocklist.txt, or when deciding which of those two files an address belongs in
---

# Throttling an IP

## Overview

Two files, and the choice between them is the whole job:

| File | What happens | What goes there |
|---|---|---|
| `custom-throttle-list.txt` | 100 kbit/s, +400 ms ± 100 ms, 3% loss | VPNs, tunnels, fronting relays |
| `custom-ip-blocklist.txt` | dropped | app estates, **and every resolver** |

**The address is cheap; the check is the work.** An unchecked address is worse
than no address — a CDN edge in either file degrades the whole house, and a
resolver in the wrong file leaves the entire name-blocking layer inert.

Both files are parsed at build time, so a typo fails the rebuild. Neither
protects you from a *valid address that should not be there*.

## Run the check before writing anything

```bash
ip=1.2.3.4
dig +short -x $ip                                    # PTR
whois $ip | grep -iE '^(inetnum|netname|NetRange|NetName|OrgName|org-name)'
whois -h whois.cymru.com " -v $ip" | tail -1         # origin AS
timeout 8 openssl s_client -connect $ip:443 -noservername </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -serial             # whose certificate?
timeout 8 curl -s -o /dev/null -w '%{http_code}\n' --resolve "cloudflare-dns.com:443:$ip" \
  "https://cloudflare-dns.com/dns-query?name=example.com&type=A" -H 'accept: application/dns-json'
```

Read the results in this order — the first match wins:

1. **PTR or AS says CDN / shared edge** (`deploy.static.akamaitechnologies.com`,
   Cloudflare, Fastly, an ISP-hosted POP) → **refuse, add nothing.** Say so and
   record why. A device talking to a CDN is what a CDN is for.
2. **DoH returns HTTP 200, or it serves `cloudflare-dns.com` / any resolver
   certificate, or it answers on 53/853** → **`custom-ip-blocklist.txt`.**
3. **Anything else that checks out as a rented instance** → throttle list.

`instances.scw.cloud`, `clients.your-server.de`, `*.vps.ovh.net`, DO-13,
`linodeusercontent.com` are all rented instances — a /32 lands on one tenant.
Judge by PTR and AS, never by netname alone (`ONLINENET_DEDICATED_SERVERS`
holds cloud instances).

## Why resolvers drop instead of shaping

This is the one place the throttle file's founding logic inverts, and it is the
mistake worth not repeating:

- Everywhere else a clean failure is **bad** — the client notices and hunts for
  another node, so shaping (no clean failure to detect) beats blocking.
- For a resolver a clean failure is **what you want** — the fallback is the
  device's system resolver, which is ours and filtered. Dropping hands the
  device back to us.
- Shaping barely touches DNS anyway. A lookup is a few hundred bytes, so the
  bitrate cap costs it nothing. Slow-but-working DoH still resolves every name
  you have sinkholed.

## Never touch these

Blocking or shaping these is self-harm, and the answer is a per-device live
rule, not a list entry:

- Akamai edge (`95.100.170.0/24` and friends) — serves the whole house
- Cloudflare `1.1.1.1` / `1.0.0.1`, and `cloudflare-dns.com` by name
- `stun.l.google.com` — discovery for every legitimate call here
- Anything Etisalat-hosted; Botim always (see the repo memory)

The throttle file's header documents the live `flow_throttle` nft table for the
CDN case. Use that, and note it must be reapplied after a reboot.

## Reading a certificate that isn't theirs

A rented instance serving `swdist.apple.com`, `a248.e.akamai.net` or
`www.marriott.com` does not hold that key — it is **relaying the handshake**,
i.e. a fronting proxy. Two variants:

- Hand it a made-up SNI (`-servername example.com`). Different cert back →
  general SNI proxy. Same cert regardless → fixed upstream.
- **Identical serial across several hosts means same upstream, NOT one image.**
  A pass-through serves whatever the upstream serves, so the match is expected
  and proves nothing about the relays sharing a build. Check it against the real
  upstream before reading anything into it:
  `openssl s_client -connect $(dig +short a248.e.akamai.net | head -1):443 -servername a248.e.akamai.net`
- **A stale certificate is the real fleet evidence.** If two hosts return an
  expired cert for a name whose live cert has since rotated, no pass-through
  can explain it — they are serving from a shared store, i.e. one image.
- Either way the behaviour is a usable fingerprint: scanning a provider's space
  for hosts answering with an upstream's certificate finds the rest. Say so in
  the note, because collecting them one at a time is the slow path.

## Sweeping the list for resolvers already in it

Grepping the file's prose for "DNS" finds only what someone wrote down. Probing
every address finds what is actually there — the first run of this found 17
resolvers sitting in the throttle list, against 3 the prose sweep had found.
**A resolver is invisible to a capture-led method**: a few hundred bytes, no
share of anything, nothing that looks like a tunnel.

- **Run it on the router.** The shaper hooks `forward`, so a probe from a LAN
  client is itself throttled and every throttled address reads as dead.
- **Reuse one SSH connection** (`ssh -M -o ControlPersist=30m -fN bongo`) —
  each fresh connection costs a hardware key touch.
- **Read the response body, not the status code.** A hosting control panel that
  returns 200 to every path looks exactly like a DoH hit. That check was the
  difference between 16 real findings and 17.
- **A bare 443 probe is not enough.** Four of the seventeen presented no
  certificate at all until the handshake carried a resolver's SNI. Only an
  actual query finds those.

## Writing the entry

- **/32 by default.** A range needs the allocation to be small and clearly the
  operator's — "nth address in a /16" is not a range case, it says where the
  client shops.
- **Say what is actually established.** If it arrived as a list with no capture,
  write that. Evidence from a capture (share, transport, direction) and evidence
  from a desk check (PTR, AS, certificate) are different things, and a later
  reader cannot tell them apart from the row.
- **Recompute any count you quote** against the file — do not carry a number
  forward from a nearby note. Several in there have been wrong in both
  directions.
- **Moving between files:** carry the note with the address and record the move
  in the destination ("MOVED HERE FROM …, and why"). Leave a pointer behind if
  the note sat inside another section's narrative.

## Verify before claiming done

```bash
cd modules/router
# exactly once, in exactly one file
for ip in <the addresses>; do
  t=$(sed 's/#.*//' custom-throttle-list.txt | grep -Ec "^${ip}[[:space:]]*$")
  b=$(sed 's/#.*//' custom-ip-blocklist.txt  | grep -Ec "^${ip}[[:space:]]*$")
  echo "$ip throttle=$t block=$b"
done
# no address in both files
comm -12 <(sed 's/#.*//' custom-throttle-list.txt | grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u) \
         <(sed 's/#.*//' custom-ip-blocklist.txt  | grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u)
# the real gate
nix build --no-link '.#nixosConfigurations.bingo.config.system.build.toplevel'
```

An address in both files is not fatal (a dropped packet never reaches the
shaper) but it reads as a decision reversed rather than duplicated. Resolve it
where the decision was made.

## Concurrent edits

These files get appended from more than one session during an inspection round.
**Re-check the tail before appending, and re-verify presence after.** Two
sessions once deduplicated the same three addresses against each other at the
same moment, each removing what it assumed the other kept — all three were in
the file zero times, silently. Duplicates are cheap; mutual deletion is not.

## Common mistakes

| Mistake | Reality |
|---|---|
| "It came from a capture, so it's a tunnel" | Two Akamai addresses were handed over in one round and nearly shaped. The capture shows the device talked to it, not what it is. |
| Checking the PTR after adding | Both Akamai near-misses were caught after the fact. Check before, every time. |
| Filing a DoH relay as a VPN | Twenty were, and had to be moved. `cloudflare-dns.com` on a droplet is a resolver, not a tunnel. |
| Judging by netname | `ONLINENET_DEDICATED_SERVERS` was a cloud instance. PTR and AS decide. |
| Taking the /24 because the /16 repeats | General-purpose cloud. The neighbours are other people's tenants. |
| Quoting a count from a nearby note | They rot within the hour during a round. Recount. |
| Blocking the fronted name | Never queried, so it cannot be denied at the resolver. The address is the only layer that bites. |
| `tempthrottle` and calling it done | Cleared by the next rebuild. Anything worth keeping goes in the file. |

## Red flags — stop and check

- About to add an address you have not run `openssl s_client` against
- The PTR mentions a CDN, or the AS is Akamai / Cloudflare / Fastly / an ISP
- The host serves a certificate for a name it obviously does not own
- You are writing a count you did not just compute
- You are about to say "added" without having built `bingo`
