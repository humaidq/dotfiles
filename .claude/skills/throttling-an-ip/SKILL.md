---
name: throttling-an-ip
description: Use when someone hands over IP addresses to throttle or block on the router, when adding entries to modules/router/custom-throttle-list.txt or custom-ip-blocklist.txt, or when deciding which of those two files an address belongs in
---

# Throttling an IP

## Overview

Two files, and the choice between them is the whole job:

| File | What happens | What goes there |
|---|---|---|
| `custom-throttle-list.txt` | 100 kbit/s cap, nothing else | VPNs, tunnels, fronting relays |
| `custom-ip-blocklist.txt` | dropped | app estates, **and every resolver** |

The throttle tier lost its 400 ms delay, 100 ms jitter and 3% loss on
2026-08-13. The clients being shaped score candidate nodes on RTT and loss, so
impairment made a shaped node *easier* to detect and discard — they moved on and
found unthrottled ones. A bare cap is near-invisible to that scoring: probes
pass under it, the node keeps measuring healthy and stays selected, and anything
carrying real data crawls. The queue is `fq_codel`, not a fifo, because a deep
fifo at 100 kbit/s is minutes of standing buffer and reads to a probe exactly
like the delay that was just removed.

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
curl -sk -v --resolve "example.com:443:$ip" https://example.com/ 2>&1 \
  | grep -iE 'subject:|issuer:'                      # whose certificate?
timeout 8 curl -s -o /tmp/doh -w '%{http_code}\n' --resolve "cloudflare-dns.com:443:$ip" \
  "https://cloudflare-dns.com/dns-query?name=example.com&type=A" -H 'accept: application/dns-json'
head -c 200 /tmp/doh                                 # the BODY decides, not the code
```

**Port 53 is blocked outbound on this network — do not probe it and do not
record its result.** A UDP or TCP/53 query times out for every address on earth
here, so "no answer on 53" is the local firewall talking, not the host. One pass
of this wrote that down as a finding for fourteen addresses before it was
caught. The resolver check that works from here is **DoH on 443**, and 853 is
worth a TCP probe. Anything already in the files claiming an address serves no
DNS on 53 is unverified unless it was probed from elsewhere.

**Probe every 443 host three times before describing it.** A single unanswered
ClientHello is not silence — these hosts drop connections intermittently. One
was written up as a silent listener and is actually a fixed-name relay; another
refused the very name it fronts on one attempt and served it on the next. Only
a repeated result goes in the row.

**Use curl, not `openssl s_client -brief </dev/null`, to read a certificate.**
With `-servername` and stdin at EOF, openssl reports no handshake at all on
hosts where curl completes one and prints the cert. That artefact produced a
confident, wrong "this host refuses named SNI" reading for five hosts in one
batch. Keep openssl for a second opinion (`-tls1_2` behaves), decide on curl.

Read the results in this order — the first match wins:

1. **PTR or AS says CDN / shared edge** (`deploy.static.akamaitechnologies.com`,
   Cloudflare, Fastly, an ISP-hosted POP) → **refuse, add nothing.** Say so and
   record why. A device talking to a CDN is what a CDN is for.

   **`Server: AkamaiGHost` does NOT mean you found a relay.** The genuine Akamai
   edge returns the identical 400 "Invalid URL" page — fetch `23.53.126.145`
   (live `a248.e.akamai.net`) and compare, byte for byte. That response only
   says an Akamai edge is on the far end, which is equally true of a relay and
   of the real thing. Two tests separate them: **the AS** (Akamai does not
   deploy edge clusters into DigitalOcean/Scaleway/THG/Hetzner tenant space) and
   **sshd** (the real edge has tcp/22 closed; every relay checked answers with
   an OpenSSH banner — a CDN appliance does not offer you a shell). Apply both
   before shaping anything in an ISP's own space.
2. **DoH returns DNS JSON in the body, or it serves `cloudflare-dns.com` / any
   resolver certificate, or it answers on 853** → **`custom-ip-blocklist.txt`.**

   **A resolver answers DNS; a tunnel merely uses the port.** Traffic on 53 is
   not evidence of a resolver — one capture showed eleven nodes fed large opaque
   UDP datagrams on port 53, which a decoder cheerfully labels "DNS". Real DNS
   in the same capture was a fraction of the size, carried a readable query name
   and went to the local resolver. All eleven were tunnel nodes and belonged in
   the throttle file. Judge the traffic, never the port number.
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

- **A different cert per SNI does NOT mean a general SNI proxy.** One Akamai
  upstream serves many brands, so it returns ICANN's `*.example.com` for
  example.com and Apple's `swcdn.apple.com` for swdist.apple.com while being a
  single fixed upstream. The discriminator is **a name the upstream does not
  host** — `www.wikipedia.org`, `github.com`, `www.google.com`. A real SNI proxy
  resolves those and returns their certificates; a pass-through falls back to
  its upstream's default (`a248.e.akamai.net`). Test with a non-Akamai name
  before calling anything a general proxy.
- Fronting is not only Akamai. A Cyprus VPS in this file relays every SNI to
  Google (`CN=*.google.com`, and `invalid2.invalid` with no SNI). Any scan that
  only tallies Akamai brands sees half the estate.
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

**A self-signed cert? whois the name in it.** One host served
`CN=qnhyg.com`, self-signed, for every SNI — and `qnhyg.com` is an unregistered
domain (VeriSign "No match", NXDOMAIN). No client ever reached it by name, so
the certificate exists purely to complete a handshake for someone who already
knows the address. Self-signed cert + nonexistent CN + empty 404 to everything
is the trojan/VLESS camouflage, and it is the strongest positive signature
available from a desk check. Cheap to run, hard to fake innocently.

Careful with the mirror case: an unregistered name in a **PTR** (one host's
reverse was `gun.superiorselm.com`, also unregistered) is just stale hosting
naming. Certificate the host actively serves ≠ leftover reverse record.

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

**Trim trailing whitespace before matching, or you will undercount.** Some
entries are `<address>    # comment` on one line. Stripping the comment leaves
trailing spaces, so a `$`-anchored match drops them silently — eight addresses
were invisible to every count taken across one long session, which made "first
88.208 address", "third 46.225 address" and a 79.142 range recount all wrong,
and put the file total 8 low throughout. The nft parser handles those lines
fine; this is a counting bug only, but this file's notes lean on counts.

```bash
cd modules/router
addrs() { sed 's/#.*//' "$1" | sed 's/[[:space:]]*$//' \
          | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
# exactly once, in exactly one file
for ip in <the addresses>; do
  echo "$ip throttle=$(addrs custom-throttle-list.txt | grep -cx "$ip")" \
       "block=$(addrs custom-ip-blocklist.txt | grep -cx "$ip")"
done
# no address in both files, and none duplicated within one
comm -12 <(addrs custom-throttle-list.txt | sort -u) \
         <(addrs custom-ip-blocklist.txt  | sort -u)
addrs custom-throttle-list.txt | sort | uniq -d
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
| Recording "no answer on 53" | Outbound 53 is blocked here. That result is the firewall, for every address. DoH is the only resolver check available. |
| Trusting `openssl -brief` on named SNI | It reports no handshake where curl completes one. Five hosts were described wrongly on that basis. |
| "Different cert per name, so it's an SNI proxy" | One Akamai upstream does that. Try wikipedia/github — a pass-through falls back to `a248.e.akamai.net`. |

## Red flags — stop and check

- About to add an address you have not run `openssl s_client` against
- The PTR mentions a CDN, or the AS is Akamai / Cloudflare / Fastly / an ISP
- The host serves a certificate for a name it obviously does not own
- You are writing a count you did not just compute
- You are about to say "added" without having built `bingo`
