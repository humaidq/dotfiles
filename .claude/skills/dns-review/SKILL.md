---
name: dns-review
description: Use when reviewing the router's DNS query log for anything unusual — an unexplained app, a gambling or casino front, a tunnel bootstrapping by name, "what has device X been resolving" — or when a window of blocky's log is too large to read. Filters known-benign domains away so only the residue needs judging.
---

# Reviewing the router's DNS log

## Overview

blocky logs every query it resolves to the journal on bongo and bingo. Two days
is around 200,000 lines and 4,900 distinct names, which is far too much to read
and almost entirely Apple, Google, Meta and CDN traffic.

`dns-review.py` cuts that to the part that carries information: it drops the
common domains, drops what was already blocked, drops local-zone noise, then
groups what is left by registrable domain and **sorts by fewest distinct
clients first** — because one device asking for something nothing else on the
network asks for is the shape a finding actually has.

Measured on a real 48h window: 199,870 lines in, 605 domains out, and the first
ten rows contained every genuine finding.

## Run it

```bash
S=.claude/skills/dns-review
sops -d secrets/router/dns-common-domains.txt > /tmp/common.txt

python3 $S/dns-review.py \
  --host bongo --since "48 hours ago" \
  --common /tmp/common.txt \
  --local-zone alq.ae --local-zone huma.id \
  --min-clients 1 | head -80
```

`--min-clients 1` is the first pass: names only one device asked for. Drop the
flag for the full residue. `--show-blocked` adds a retry-count summary of what
was already sinkholed, which is how you tell a block that is working from a
block nothing has tested.

To work offline from one capture — always prefer this if you will run more than
one pass, since pulling 200k lines over ssh is the slow part:

```bash
ssh bongo 'journalctl -u blocky --since "48 hours ago" --no-pager -o cat' > /tmp/raw.log
python3 $S/dns-review.py --file /tmp/raw.log --common /tmp/common.txt --local-zone alq.ae
```

**Reuse one ssh connection.** Every fresh one costs a hardware key touch; the
script sets a `ControlMaster` for exactly this reason.

## Reading the output

Each block is one registrable domain, with the names under it and which clients
asked:

```
mynt.xyz   [105 queries, 1 client(s)]
       50  mdap.paas.mynt.xyz          CACHED/RESOLVED  cristina-phone(50)
        4  sendmoney.mynt.xyz          RESOLVED         cristina-phone(4)
```

Judge in this order:

1. **How many clients?** One is interesting; fifteen is infrastructure you have
   not put in the common list yet.
2. **What are the subdomain names?** `sendmoney`, `lending`, `login` name the
   product. A random-looking label under a coined domain is the fronting shape
   the blocklist already documents.
3. **RESOLVED or BLOCKED?** RESOLVED means it worked. That is the finding.
4. **Only then** run the desk checks — PTR, AS, certificate. The
   `throttling-an-ip` skill has the procedure and its failure modes.

## Growing the common list is the actual work

The filter is only as good as `secrets/router/dns-common-domains.txt`. Every
domain you clear as boring should go in, and the file gets better every pass.

```bash
.claude/skills/editing-sops-lists/lists.sh edit dns-common-domains
```

**The rule for adding an entry is narrower than "I recognise it":** a lookup
must tell you nothing you would act on. True of a vendor's own infrastructure.

**Never add multi-tenant hosting.** `amazonaws.com`, `cloudfront.net`,
`azurewebsites.net`, `workers.dev`, `herokuapp.com`, `execute-api`, `*.r2.dev`,
ngrok, trycloudflare, dynamic-DNS providers, pastebins and URL shorteners are
deliberately absent from that file. The subdomain there identifies a *tenant*,
and the tenant is the entire question — `custom-blocklist.txt` already carries
`execute-api` and `azurewebsites` entries found exactly this way. Adding the
parent would have hidden them.

The script prints what each common entry folded away:

```
#     10349 queries,  150 distinct names  apple.com
```

If a line is hiding an implausible number of distinct names, look at it before
trusting it.

## What this will not show you

- **A name that was never looked up.** A device with a hardcoded IP, or one
  using DoH the router has not blocked, resolves nothing here. That is the
  `detecting-client-tunnels` skill's job, from a capture.
- **Who, reliably.** `client_names` is a DHCP/PTR label. A rotated MAC shows up
  as a bare address; the repo memory on netwatch MAC rotation applies.
- **IPv6-only detail.** Clients appear under link-local `fe80::` addresses as
  often as under names, and the same device shows up as both.
- **Anything outside journald retention.** Check the window really covers what
  you asked for before reporting "nothing found".

## Verify before reporting

- Quote counts you just computed, not ones from earlier in the session.
- Separate what a client did from what **you** did. Lookups from `127.0.0.1`
  and from the mesh addresses of admin hosts are your own investigation — a
  previous session's `dig` from anoa shows up identically to a device, and has
  been misread as a finding.
- If you say something is blocked, prove it against the live resolver rather
  than against the file: `ssh bongo 'dig +short @127.0.0.1 <name>'` returning
  `0.0.0.0` is the proof. The file says what should happen; the resolver says
  what does.

## Common mistakes

| Mistake | Reality |
|---|---|
| Running without `--common` and reading 600 domains | The filter is the point. It says when it skipped that stage. |
| Treating an upstream gambling/adult list as coverage | HaGeZi's gambling list matched 4 names in a real 48h window; the custom blocklist caught everything that mattered. Coined fronts rotate faster than public lists. |
| Reading `127.0.0.1` or a mesh IP as a client | That is the router, or you. |
| "It resolved, so it's not blocked" | Check the timestamp against when the entry was added and deployed. |
| Adding a cloud parent domain to the common list | Hides the tenant, which is the question. |
| Grepping `modules/router/` to check coverage | The lists are encrypted now — see `editing-sops-lists`. |
| Reporting a domain as absent from the blocklist | A CIDR or a wildcard may already cover it; check containment, not string match. |
