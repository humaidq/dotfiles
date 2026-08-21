---
name: blocking-apps-by-domain
description: Use when blocking an app, game, or website on the home network, adding entries to modules/router/custom-blocklist.txt, or when something that was supposedly blocked still works
---

# Blocking apps by domain

## Overview

Blocking an app's marketing domain usually does nothing. Live-streaming and
random-chat apps in particular ship several interchangeable backends and fail
over silently — Crush Live carries seven, each with an identical
`api.`/`h5.`/`image.`/`proxy.` host layout. The domains they actually talk to
are in the APK, and generally share nothing with the brand name.

So: **get the domains out of the package, verify them against the router, then
block wildcards.** Never block from a web search alone.

## Steps

1. **Find the Android package name** (`com.metaztech.chatta`). Search for the
   app on Google Play; the `id=` query parameter is the package.

2. **Extract candidate hosts:**
   ```bash
   nix shell nixpkgs#curl nixpkgs#unzip nixpkgs#binutils nixpkgs#file
   ./apk-domains.sh com.metaztech.chatta | tee /tmp/cands.txt
   ```
   Output is candidates, not answers — string tables leak plenty of junk.

3. **If the package yields little, or is packed, PAIR-wrapped, or rotates
   domains, run it:**
   ```bash
   nix shell nixpkgs#android-tools nixpkgs#wireshark-cli nixpkgs#jdk17_headless \
     nixpkgs#curl nixpkgs#file nixpkgs#unzip
   ./apk-sim.sh com.olamet.mobile | tee -a /tmp/cands.txt
   ```
   Boots an emulator, drives the app with a seeded monkey, and reports what it
   actually dialled during that run — bare hostnames on stdout for the same
   candidate file, an annotated table on stderr tagging each host `SNI` (a TLS
   connection opened — the strongest signal there is), `DNS` (looked up,
   never connected), `HTTP` (a cleartext Host header), or `IP` (connected to
   an address no DNS answer mentioned — a hardcoded resolver; see "Missing an
   HTTPDNS bypass" below). A host the app was observed dialling is stronger
   evidence than a string in a dex. The two tools are complementary — take
   the union.

   This is a fallback, not a replacement for step 2 — it needs an emulator
   boot and several minutes per run, against seconds for static extraction.
   Reach for it once the dex comes back thin, not as the default first move.
   Defaults to a 120s window (`-t`) and the router itself as resolver (`-d
   10.20.0.1`), not a clean upstream, so a blocked primary forces the app to
   fail over instead of just working; `-l <file.apk>` skips the download if
   you already have the package.

4. **Verify against the live resolver** (needs to run on the LAN, or use
   `-s 10.10.0.16` over Nebula):
   ```bash
   ./check-domains.sh < /tmp/cands.txt
   ```
   `BLOCKED` means an upstream list already caught it — that is a useful signal
   the domain is malicious, not a reason to skip it. Keep `NXDOMAIN` entries if
   they are clearly the operator's; these outfits rotate.

5. **Add wildcards** to `modules/router/custom-blocklist.txt`, grouped under a
   comment naming the package. `*.example.com` blocks the apex *and* every
   subdomain (blocky normalises it to a trie prefix), so one line per registered
   domain is enough.

6. **Rebuild and confirm:** `sudo nixos-rebuild switch --flake .#bongo` on
   bongo, then re-run `check-domains.sh` over the added names, plus a few hosts
   that must keep working.

   **Never run `nix flake check` for a blocklist change.** It builds every host
   in the repo to validate a text file that is not even Nix, which costs many
   minutes for zero signal. This overrides the general instruction in
   `CLAUDE.md` to run it before pushing. The rebuild on bongo is the check.

## The hardcoded fallback pool is usually in the dex — grep for IPs, not names

The `sg.bigo.overwall` backup LBS is the one layer no `custom-blocklist.txt`
entry can reach, and the natural assumption is that it must therefore be hidden.
It is not. In `sg.bigo.live`, 22 of the 23 addresses a runtime capture recorded
are plain ASCII in `classes.dex`, in **one contiguous run of the string table**
— the table is sorted, so every dotted quad lands together and the whole pool
reads off in one grep:

```bash
find x -name '*.dex' -print0 | xargs -0 strings -n 7 |
  grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | sort -u
```

This is strictly better than capturing. A run dials whatever subset its path
through the app needed; the dex holds the entire list. BIGO's 23 captured
addresses turned out to be part of a 48-address pool, and reading it gave 26
more that no capture had seen. Only the address that carried the *real* session
was absent — that one is handed out by the LBS at runtime.

Two traps produced the opposite, wrong conclusion the first time:

- **An `apk-sim.sh` work directory contains no extracted tree.** It holds
  `app.apk`, `bundle/` and the pcap, nothing else. A `find … -name '*.dex'`
  there matches nothing, so a search "of the package" silently searches an empty
  set. The two tools share `$TMPDIR/apk-domains/<pkg>/`; only `apk-domains.sh`
  populates `x/`.
- **`app.apk` is often an Android bundle.** Unzipping it yields inner split
  APKs and *no dex at all*. `apk-domains.sh` unzips the inner APKs already; a
  manual `unzip app.apk` does not.

If a search comes back empty, confirm it searched something before believing
it: `find x -name '*.dex' | wc -l`.

Triage the resulting addresses the same way as hostnames — most are not
backends:

| Category | What it looks like |
|---|---|
| Public resolvers | imo embeds Quad9, OpenDNS, CleanBrowsing, AdGuard, Norton, Comcast, Level3, Google, Cloudflare — its `NetworkDiagnosticTool` probe set. Blocking any of it is self-harm. |
| Shared cloud | AWS eu-west/eu-central, Google Cloud — excluded on the usual rule |
| Parsing junk | X.509 OIDs (`2.5.29.37`, `1.3.6.1`) and version strings (`3.6.0.0`) match the dotted-quad regex |
| **Operator AS** | the real target — map every address to its origin AS first |
| **Rented hosting** | Zenlayer, GNET and similar; being written into the operator's own binary is the strongest attribution there is, so /32s are justified even on shared hosting |

## Resolving real addresses: keep one ssh socket to bongo

`check-domains.sh` tells you whether blocky answers `0.0.0.0`. It cannot tell
you what a name *really* resolves to, and no host on the LAN can: the router
drops forwarded port 53, DoT on 853 and every known DoH endpoint, which is the
whole point. `dig @8.8.8.8` from a workstation just times out.

Run the digs on bongo instead — the router's own output path reaches upstream
fine. Open **one** ControlMaster socket and reuse it; every fresh `ssh` needs a
touch on the hardware key, and the socket makes the rest free:

```bash
SOCK=/tmp/claude-1000/bongo.sock            # short path — see below
ssh -M -S "$SOCK" -o ControlPersist=8h -fN bongo
ssh -S "$SOCK" bongo 'dig +short @8.8.8.8 newlbs.live.bigo.sg'
```

Things that will bite:

- **Keep the socket path short.** A Unix socket path has a ~100 char limit, and
  the session scratchpad directory blows past it (`unix_listener: path ... too
  long`). `/tmp/claude-1000/` is fine.
- **bongo's login shell is zsh and it has no `python3` and no `nc`.** Bash-isms
  fail there — `/dev/tcp/host/43` is a bash feature zsh does not implement, so
  the usual whois-over-TCP trick dies. Push a script with `ssh ... 'cat > /tmp/x'`
  and drive it with `xargs -P`, or use `curl`, which is present.
- **`sudo` on bongo wants a password.** `nft list set` and `nixos-rebuild` are
  the user's job; ask rather than trying to work around it.
- **Verify enforcement from the LAN instead**, which needs no sudo: a plain TCP
  connect to a listed address should hang while a control host connects.
  `timeout 6 bash -c 'cat </dev/null >/dev/tcp/169.136.94.251/443'`. Do not use
  `1.1.1.1` as the control — it is a DoH endpoint and is blocked on 443.

### What this is for: mapping the estate instead of chasing addresses

Resolution is the counterpart to a runtime capture. A capture shows the handful
of addresses one run happened to dial; resolving every hostname you know shows
the whole pool, and grouping *that* by origin AS is what turns a pile of /32s
into a single decision.

Feed it the concrete hostnames — grep the dex trees for names under the zones
already in `custom-blocklist.txt`, and add the DNS query names from any pcap you
have (`tshark -r capture.pcap -Y 'dns.flags.response==0' -T fields -e
dns.qry.name`). Resolve **several times**: these names are round-robined over
rotating subsets, and one pass understates the pool badly — BIGO's `newlbs`
went from 2 addresses to 10 across six rounds.

Map each address to its origin AS with Cymru's DNS interface, which needs only
`dig` and so works over the socket:

```bash
dig +short @8.8.8.8 "$(echo 1.2.3.4 | awk -F. '{print $4"."$3"."$2"."$1}').origin.asn.cymru.com" TXT
dig +short @8.8.8.8 AS10122.asn.cymru.com TXT      # name the AS
```

Then pull the operator AS's announced prefixes and collapse them:

```bash
curl -sS "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS10122"
```

The decision rule is the same one the rest of this file uses, just applied at
the AS level. An AS whose every hostname is the operator's — AS36131 for imo,
AS10122 (NETSTAR) for BIGO — is single-tenant, so block all of it. Cloudflare,
CloudFront, Alibaba and Zenlayer answers are shared and stay unblocked no matter
how many operator names point at them. In between sit small hosting ASes where
the operator rents: check whether the pool grows across rounds, and if a /24
yields only a handful of addresses that never change, block those as /32s rather
than taking the /24 — it is somebody else's tenant too.

## Triage: what not to block

Most hosts in an APK belong to somebody else. Blocking them breaks unrelated
apps for the whole house. `apk-domains.sh` filters the common ones, but check
anything you do not recognise.

| Category | Examples seen in these apps |
|---|---|
| RTC / IM SDKs | Agora, ZEGO, RongCloud, NetEase Yunxin |
| Attribution / analytics | Adjust, Kochava, AppsFlyer, SensorsData, ByteDance APM |
| Payments | GCash, Mynt, Razorpay, PhonePe, Paytm |
| Identity / anti-fraud | Alibaba `authidv`/`yunverify`, hCaptcha, Forter |
| Shared CDN zones | `tiktokcdn.com` also serves thumbnails and the web app |

For a shared zone, anchor on the hostname prefix rather than blocking the zone:
`/^(?:pull|push)-[^.]+\.tiktokcdn\.com$/` kills TikTok LIVE while leaving
`p16-*` thumbnails and `v19` video alone.

## Correlating operators

Finding the shared backend is worth more than chasing each brand: Achat, Seeta
and the six BoloJi packages all call `leadercc.com`, `quantum-nexus.net` and the
`akisinn`/`dewrain`/`vaicore` pool, so blocking that pool covers all of them.

**Correlate on hostnames in the packages, not on IPs.** Nearly every app in this
category fronts with a Chinese CDN, so a shared address usually means "both
bought Alibaba Cloud CDN", nothing more. Always look at the CNAME chain before
drawing a conclusion:

```
chamet.com   → chamet.com.w.cdngslb.com  → 98.98.238.183-190   # Alibaba CDN
tango.tv     → tango.tv.w.cdngslb.com    → 98.98.238.183-190   # same POP, unrelated
api.2-b.xyz  → 43.163.40.175                                   # no CNAME: real origin
```

`cdngslb.com`, `kunlunsl.com`, `kunlungr.com`, `kunlunca.com`, `lahuashanbx.com`
are Alibaba; `eo.dnse2.com`, `eo.dnse3.com` and `ovscdns.com` are Tencent
EdgeOne; `whecloud.com` is Wangsu; `rgslb.net` and `fastecn.com` front further
CDNs. A shared IP behind any of those proves nothing. A shared IP on a direct
A record — like the three GOGO Live API domains above — is real evidence.

`vecdnlb.com`/`vedcdnlb.com` are ByteDance Volcengine — Olamet's whole estate
sits on `98.98.251.23` behind those, which looks damning and means nothing. Its
`volc-dcdn` server banner is shared edge software and is equally worthless.

The same trap makes CDN ranges bad nftables targets: dropping `98.98.238.0/24`
would have blocked an Alibaba CDN POP serving arbitrary unrelated sites.

**Read the TLS certificate — it is the single best correlator.** Operators put
every brand they run on one cert, so a SAN list maps the whole estate in one
request:

```bash
echo | openssl s_client -connect <host>:443 -servername <host> 2>/dev/null |
  openssl x509 -noout -ext subjectAltName
```

`mobile-f.livechat-internal.com` returns SANs for `api.rabbitvideochat.com`,
`api.sohbetiko.com`, `api.pinkvideochat.com`, `api.salsavideochat.com` and
`api.karamelchat.com` — six brands, one operator, no guesswork. Certs also
settle tenancy: `olamet.im.wooyavip.com` is named on its own cert, and a
tenant-specific Alibaba ALB or Tencent CLB instance in a CNAME
(`alb-n9mrrja5gykl0coqkn...`) is real evidence where a bare CDN POP is not.

Note the inverse: a cert proves nothing when it is the CDN's own default, and a
mismatched cert is usually just a parked host — `inlandcha.com` presents
`td.01bite.net`.

## blocky specifics

- `blockType` is `zeroIp`, so a blocked name answers `0.0.0.0`, never NXDOMAIN.
- Regex entries are `/^host$/`, matched by Go's RE2: `(?:...)` works,
  lookahead does not.
- **Allowlists beat denylists unconditionally.** `logproxy.imoim.app` cannot be
  blocked locally because hagezi's anti-piracy list — used as an *allowlist* in
  `blocky-common.nix` — contains `*.imoim.app`. Check the allowlists before
  concluding an entry is broken.
- `custom-blocklist.txt` is shared with hisn via `blocky-common.nix`.

## When the package will not download

APKPure is the default and covers most apps, but it 404s on some and returns
410 for delisted ones. Then, in rough order of usefulness:

- **APKMirror** has the widest catalogue and is also the way to find a package
  name you cannot otherwise pin down — search `?post_type=app_release&s=<pkg>`
  and read the `.png` icon filenames. Its final download link is behind bot
  protection, so expect to fetch the file by hand.
- **`apkfab.com` is in this repo's own blocklist**, so it will hang rather than
  fail cleanly.
- **Uptodown will happily serve you its own store client instead of the app.**
  `apk-domains.sh` now refuses to continue when the manifest does not contain
  the requested package, because that download extracts perfectly and yields
  hundreds of plausible-looking ad-tech domains from its consent SDK.

If no mirror works, fall back to the vendor's website: pull its JS bundles and
grep for hosts. That is how Poppo Live's `vshowapi.com` and `vshow-live.com`
backends were found. Coverage is weaker — endpoints only the app calls will not
appear — so say so when reporting.

## When the package downloads but yields nothing

A clean extraction with no operator hosts is a result, not a failure — read why
before falling back:

- **PAIR-wrapped.** `com.pairip.application.App` in the manifest means Google
  Play's integrity wrapper has encrypted the payload (ZaffaLive). Nothing is
  recoverable.
- **Runtime config.** Chato's 37 MB dex contains only SDK strings; the API base
  is fetched or assembled at runtime.
- **Split APKs.** The mirror may serve a base APK with no `lib/*.so`. If
  `find … -name '*.so'` comes back empty, native strings were never in scope.

Two things still work. The **binary manifest and `resources.arsc`** often keep
hosts the dex lost — that is where Chato's AppsFlyer vanity host
`chato.go.link` surfaced (`strings -a -e l` for the UTF-16 tables). And the
**store listing's privacy-policy URL** names the operator's domain: JoyChat's
`joyme.chat` came from there, with live `api.` and `ws.` hosts confirming it.

Better than either: run the app. `apk-sim.sh` boots it under an emulator with
packet capture and reports what it actually contacted, which is unaffected by
packing, obfuscation or runtime-assembled URLs. It is the first thing to reach
for when the dex comes back empty.

Say plainly in the write-up that such an entry is brand-only, and note that the
query log and a runtime capture (`apk-sim.sh`) are both ways to catch what it
missed.

## The noise filter hides failover infrastructure

`apk-domains.sh` drops big-CDN and SDK zones so the candidate list stays
readable, but an app's *escape hatches* live in exactly those zones. The
filtered output is therefore never the whole story — always grep the raw
strings separately:

```bash
t=/tmp/apk-domains/<pkg>/x
find "$t" -name 'classes*.dex' -print0 | xargs -0 strings -n 6 |
  grep -oE '[a-z0-9]+\.cloudfront\.net|httpdns[^"]*' | sort -u
```

SoulChill (`com.live.soulchill`) ships a hardcoded JSON map pairing every one
of its hosts with a CloudFront mirror, so blocking `soulchill.live` alone just
makes the app fail over. Gemgala resolves through `httpdns.baidubce.com`, which
never appeared as a candidate because `baidubce` is on the noise list.

Block the exact `dXXXXXXXX.cloudfront.net` distribution hostnames — a
distribution ID belongs to a single AWS account, so it is precise. Never
wildcard `cloudfront.net`, `akamaized.net` or the like.

Before blocking one, prove whose it is — an ad SDK bundled in the same app also
ships distributions, and those are shared with unrelated apps. The cert is no
help (they all serve the default `*.cloudfront.net`), and the dex string table
is sorted alphabetically, so neighbouring strings tell you nothing about the
owning class. **Probe the origin instead** and compare it to a host you already
know is the operator's:

```bash
curl -sS -X POST --data x https://dXXXX.cloudfront.net/ -D- -o /dev/null
```

Likee's nine distributions answer with `bigotraceresponse` and CORS headers
listing `bigo-appid`/`bigo-uid`/`bigo-signature`, and `https-api.like.video`
returns the same `openresty` 405 — conclusive. Response headers, error-page
fingerprints and `Server:` banners survive domain fronting; certificates and
IPs do not.

## Runtime domain rotation

Some apps do not ship a fixed backend list at all — they fetch one. Olamet
(`com.olamet.mobile`) bundles a first-party SDK under `com.hule.*` with
`DynamicDomainManager` and `OKHttpDns`, and calls
`http://tools.hulekeji.com:30561/domain/get` for fresh domains whenever the
current ones stop resolving. It also carries a `NetworkDiagnosticTool` that
queries ipinfo/ipwhois/geojs to determine whether it is being filtered.

Against an app like this, blocking the brand zones is worse than useless — it
is the trigger. **Block the rotation service first.** Find it by grepping the
dex for the machinery rather than for hostnames:

```bash
strings -n 8 classes*.dex |
  grep -iE 'DynamicDomain|DomainManager|/domain/(get|list)|getHttpDnsUrl|backupDomain|domainConfig'
```

Class names survive obfuscation more often than you would expect, because the
SDK is usually a separate module the app author did not obfuscate. A hit like
`com/hule/domain/manager/DynamicDomainManager` also names the vendor — `hule`
→ `hulekeji.com` — which is the zone to block.

Probing the endpoint to enumerate the pool is worth one attempt, but they
generally want a signed parameter set and answer `{"code":400}` otherwise.
Blocking the zone disables the mechanism regardless, so do not sink time into
it.

## What the runtime capture does not see

`apk-sim.sh` stops at the login wall. These apps demand a phone number and an
OTP, and nothing automates that. What it captures is the splash, the config
fetch, the API handshake and any rotation traffic — the layer the blocklist
targets — but **not** post-login media CDNs or RTC backends. Those still need
the string table or the query log.

Further limits, all of which belong in the write-up whenever a finding came
from a run:

- **Some apps detect the emulator** and exit. The script warns when the
  process dies early rather than returning a silent empty list, but a warned
  run's host list is incomplete by definition. A genuine emulator crash
  (qemu itself dying — reproducible on `com.duckduckgo.mobile.android` under
  monkey fuzzing) is a different failure again; the script tells the two
  apart, but either one voids the run. Retry it; do not interpret it.
- **A run is one path through the UI.** The monkey is seeded, so it is
  reproducible, not exhaustive.
- **Confirm the blocklist is actually enforced on the router before drawing
  any conclusion from a run.** `apk-sim.sh` defaults to the router itself as
  resolver precisely so a blocked primary forces the app to fail over and
  expose its rotation service or CDN mirrors. Run against `com.olamet.mobile`
  and `com.live.soulchill`: both rediscovered their known zones cleanly via
  `SNI`, but neither `tools.hulekeji.com` nor a CloudFront mirror ever
  appeared, because every relevant `custom-blocklist.txt` entry still
  resolved live on `10.20.0.1` — the entries existed in the file, but bongo
  had not been rebuilt since they were added. An unenforced blocklist
  silently removes the failover signal and leaves a run indistinguishable
  from "this app has no fallback."
- **Failover is real, and DNS blocking alone does not stop it.** Confirmed on
  `com.imo.android.imoim` in the first run against a properly rebuilt bongo:
  all fifteen of its hostnames answered `0.0.0.0` and none was ever connected
  to, yet the app held a 184s session on `83.229.96.64:443` and ~91s each on
  two Tencent Cloud addresses, over a non-TLS protocol, against IPs named in
  no DNS answer in the capture. That is `sg.bigo.overwall`'s
  `IBackupLbsConfig`. When a run's table shows every hostname as `DNS` with no
  `SNI` but the `IP` section is populated, the blocklist is working and the
  app is winning anyway — go to `custom-imo-list.txt` (what that file's
  addresses get is per-host and per-day, set by `sifr.router.imoPolicy`:
  dropped on bongo, blocked on odd days and shaped on even ones on bingo),
  and prefer the operator's own AS (imo announces 27 prefixes from AS36131,
  PageBites) over individual addresses on shared clouds, which rotate.
- **The packed-app case — the tool's original justification — remains
  unproven, not disproven.** See "Trusting a packed APK" below for what
  actually happened when it was pointed at Chamet and MateMet. (Chatta, used
  above as the walkthrough example, is not packed — correct that assumption
  if you carry it forward.)

Say plainly which tool produced which entry. Best coverage is the union of
`apk-domains.sh` and `apk-sim.sh`, and neither alone is the whole story.

## Common mistakes

- **Blocking a legitimate same-name site.** `com.boloji.live`'s reverse-DNS
  suggests `boloji.com`, which is an unrelated Indian literary magazine. Fetch
  a domain before blocking it.
- **Blocking a parked domain.** By far the most common false positive: an
  operator lets a domain lapse, a squatter picks it up, and it still resolves.
  `serveroute.com`, `countryname.com`, `litshow.com`, `chato.chat` and
  `gemgala.com` were all parked. The tells are a 302 to `hugedomains.com`
  (served by `Kestrel`) or to `atom.com` (served by `openresty`), and the AWS
  parking addresses `76.223.54.146` / `13.248.169.48`. One `curl -D-` settles
  it, and blocking one is pure noise in the file.
- **Blocking payment infrastructure.** ShareChat's package contains
  `netbanking.hdfcbank.com`, `secure.axisbank.com`, `merchant.onlinesbi.com`
  and several `arcot.com` 3-D Secure hosts. They are checkout redirect targets.
  Blocking them would break banking for the whole house, not just the app.
- **Trusting a packed APK.** If `apk-domains.sh` warns about a tiny dex (Chamet
  and MateMet both ship ~74 KiB stubs, with `libplt-base.so` and
  `libNetHTProtect.so` alongside), the code is encrypted — the manifest and
  resources are stripped too. `apk-sim.sh` was built as the answer to exactly
  this case, but pointed at these same two packages (twice each) it found
  nothing either: both detect the emulator and exit before making a call of
  their own. Use brand domains and watch blocky's query log; a runtime
  capture is not (yet) a way past this specific app family.
- **Mistaking a package name for a host.** Reverse-DNS package names survive
  extraction: `sg.bigo.live` and `video.like` are Android packages, not
  hostnames. They are left in the output deliberately rather than filtered,
  since real hosts do start with labels like `sg.`. Flutter plugin namespaces
  are the same trap in a less obvious costume — `plugins.justsoft.xyz` looks
  like a live host next to the familiar `plugins.flutter.io`, and is not one.
- **Missing an HTTPDNS bypass.** GOGO Live resolves through
  `intl.httpdns.gold`, Tencent's HTTPDNS — DNS over HTTPS by another name,
  and absent from hagezi's DoH list. Grep the candidates for `httpdns`. These
  SDKs often hardcode the resolver IP, in which case only an nftables rule
  stops them. Grep the *raw strings*, not the candidates — Baidu's
  `httpdns.baidubce.com` is filtered out as SDK noise before you ever see it.
  `apk-sim.sh` detects this case directly: its `IP` tag lists every address the
  app connected to that no DNS answer in the capture mentioned, which is
  exactly the signature of a hardcoded resolver.
- **Blocking source code that looks like a host.** Several TLDs collide with
  ordinary code. `.xyz` is a GLSL swizzle, so Unreal and Unity shaders in
  `assets/` yield `data.customdata0.xyz` out of
  `Data.CustomData0.xyz = IrisNormal;`. `.top` is a CSS property, so any
  bundled JS yields `img.style.top` — which resolves, because someone owns
  `style.top`. Resolving is therefore not evidence. Grep a suspicious
  candidate back to its context before blocking it.
- **Blocking the apex only.** Use `*.domain`, never bare `domain`.
