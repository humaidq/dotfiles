# Low-trust device pool: stricter egress for named devices, on bingo

## Problem

Every egress control this router has is applied to the whole LAN. The blocklists,
the throttle list, the port blocklist and the DoH block all key on the
destination; nothing keys on which device is talking. That is the right shape for
"this address is a tunnel node" and the wrong shape for "this device is not
trusted with the open internet".

Two things force the issue.

The first is scale. The 12–13 Aug session added over two hundred addresses to
`custom-throttle-list.txt`, and the captures that produced them showed why the
list keeps growing: the client holds a pool of candidate nodes, probes them, and
selects one, refreshing the pool from a control channel fronted behind Akamai.
Adding nodes one at a time is losing to a supply that regenerates. A device-scoped
rule stops depending on knowing the node in advance.

The second is that the QoS layer is being used against itself. `qos-mark` grants
high priority to any UDP flow carrying the STUN magic cookie, which is how real
calls get into CAKE's Voice tin without anyone maintaining a port list. A tunnel
that speaks ICE inherits that priority. The captures show the tunnel running its
own STUN, so this is not incidental.

## Scope

bingo only. bongo is untouched, and the module default is off, so a router that
sets nothing behaves exactly as it does today.

## Membership

`sifr.router.lowTrust.enable`, plus two nftables sets of type `ether_addr` in the
existing `inet router-blocklists` table.

| set | source | lifetime |
| --- | --- | --- |
| `lowtrust_macs` | sops secret, loaded at runtime | reloaded when the loader runs: boot, rebuild, or `systemctl restart` |
| `lowtrust_macs_temp` | `lowtrust` CLI and the peers page | until removed, or until the next rebuild reloads the ruleset |

MAC rather than IP, chosen over a pinned-DHCP-lease scheme because it survives a
device setting its own address. The known weakness is recorded rather than
designed around: a device that randomises its MAC leaves the pool silently, and
this repo's own notes document MAC rotation happening on this network. There is
no mitigation in this design. If it becomes a problem the answer is the hybrid —
match `ether saddr` **or** a reserved DHCP range — not a different primary key.

### Why the MAC list is a secret

This repository is public. A MAC address identifies a person's device, and the
list is by construction a list of who is not trusted. It goes in
`secrets/bingo.yaml` as `lowtrust-macs`, one MAC per line, `#` comments, matching
the format conventions of the plaintext lists.

The nft ruleset is generated at build time into the Nix store, which is
world-readable, so the secret cannot be interpolated into it. A
`nft-lowtrust-macs.service` reads the decrypted path at runtime and populates the
set with `nft add element`. The store holds only the path.

### Why two sets rather than one

So that "remove" is safe. The peers page can only mutate `lowtrust_macs_temp`, so
a button press can never silently undo a device that was deliberately put in the
permanent list. A device in both is simply in the pool. Both sets feed one policy
through a jump, so the rules are written once:

```
chain forward_lowtrust {                       # hook forward, priority -10
  ether saddr @lowtrust_macs      jump lowtrust_policy
  ether saddr @lowtrust_macs_temp jump lowtrust_policy
}
chain lowtrust_policy { ... }                  # regular chain, no hook
```

## What the pool blocks

All rules live in `lowtrust_policy`, scoped `iifname lan0 oifname ppp`, so only
LAN-to-WAN traffic is affected and LAN-local traffic between devices is not.

Traffic to the router itself — DHCP, DNS — is untouched for a different reason
and needs no rule: it arrives at the `input` hook, and every chain here is on
`forward`. Worth stating because it is load-bearing. A pool device must keep
reaching the router's resolver; one that cannot falls back to something worse,
which is the opposite of the intent.

Priority -10 matches `forward_ports` and `forward_blocklists`, which puts these
drops ahead of `forward_throttle` at 0. A pool device reaching a throttled
address is dropped rather than shaped, consistent with the existing precedence.

Each drop gets a rate-limited log rule with prefix `nft-block-lowtrust`, written
as a separate rule from the verdict. The existing chains document why: a limit on
the verdict rule would let packets over the rate escape the drop.

### Ports

`custom-lowtrust-ports.txt`, seeded with 21, 22, 553 and 554 — the ports the
13 Aug captures showed the tunnel using as camouflage. Separate from the global
`blocked_ports`, which is unchanged. Port 22 in particular is deliberately not
global: SSH from other devices on this LAN is legitimate.

### Subnets

`custom-lowtrust-subnets.txt`, an interval set, so blanket entries at `/16` or
wider can be written where a provider is not worth enumerating host by host. A
subnet is not device-identifying, so this file stays in git where it is
reviewable.

### STUN — narrowly

**Not by signature.** Dropping every packet carrying the STUN magic cookie was
considered and rejected: it would break Botim, Comera and GoChat, which must keep
working on these devices.

Instead, a `lowtrust_stun4/6` set holding the generic public STUN servers used
for NAT discovery — `stun.l.google.com`, `stun.nextcloud.com`,
`stun.voip.blackberry.com`. The file lists **names**, and a timer-driven service
resolves them into the set, because those addresses move.

The drop is scoped to UDP ports 3478, 5349 and 19302 rather than applied to the
whole address. `stun.l.google.com` resolves onto Google edge addresses shared
with unrelated services; dropping the address wholesale would break other Google
traffic on the device, where port-scoped the collateral is only STUN. App-specific
STUN and TURN are untouched, because they are not in the list.

## QoS

Pool devices never reach the Voice tin. Not for the tunnel, and not for calls
either — Botim, Comera and GoChat land in best-effort along with everything else.
They are never dropped, so calls still work; they lose priority under load, which
is accepted.

An earlier draft granted priority by destination from a maintained
`call_endpoints` allow-list. It was dropped: it would have needed a capture of a
real call per app to seed, and it buys nothing once the requirement is "no Voice
tin for these devices" rather than "no Voice tin for the tunnel".

Four rules in `qos-mark`, placed **after** the existing mark rules and **before**
the ct-mark-to-DSCP translation:

```
ether saddr @lowtrust_macs      counter ct mark set 0
ether saddr @lowtrust_macs_temp counter ct mark set 0
ether saddr @lowtrust_macs      ip dscp set cs0    (+ ip6 form)
ether saddr @lowtrust_macs_temp ip dscp set cs0    (+ ip6 form)
```

Two mechanisms make this work, both already load-bearing elsewhere in the file:

- **`ether saddr` only matches upload.** A download's source MAC is the ISP's.
  This is fine because the mark lands on the *conntrack entry*, so every packet
  of the conversation inherits it in both directions — the same property the
  STUN rule's own comment describes as load-bearing.
- **Placement after the mark rules** means this overwrites any high-priority mark
  the port list or the STUN signature just set, rather than being overwritten.

The DSCP bleach closes a hole that exists today independently of this feature.
The router bleaches DSCP arriving from the WAN, but a LAN device's own upload
codepoint is untouched, so a device can mark its own packets EF and reach the
Voice tin on the uplink regardless of its ct mark.

Normal devices are unaffected: every rule is gated on set membership, and the
sets are empty on a router that has not enabled the feature.

## Peers page

A `lowtrust` tool alongside `tempblock` and `tempthrottle`: `add`, `del`, `list`,
`status`. The peers page is per-device-IP, so `add` resolves IP to MAC from the
neighbour table and adds the MAC to `lowtrust_macs_temp`. A resolution failure
exits non-zero; `runTool` already surfaces tool output, so a failed action is not
reported as a success.

Two `peerAction` entries, both `peerless: true` because they act on the device
rather than on a peer:

- `POST /peers/{device}/lowtrust`
- `POST /peers/{device}/lowtrust/remove`

Registering them as `peerAction` data rather than as bespoke handlers inherits
the same-origin check, the journal line and the error handling that every other
button on the page already gets — the comment on that type says a route which
forgot one would be an unauthenticated firewall mutation.

The device page grows a badge showing membership and which set it came from. A
device in the permanent set shows the badge with **no** remove button: that
button could not work, and offering it would be a lie.

## Error handling

| condition | behaviour |
| --- | --- |
| feature enabled, secret missing or unreadable | loader unit **fails**, visible in `systemctl --failed` |
| malformed MAC in the secret | loader unit fails; no partial load |
| `lowtrust add` cannot resolve IP to MAC | non-zero exit, message shown on the peers page |
| feature disabled | no sets, no chains, no service, no tool |

The loader fails loudly rather than starting with an empty set, because an empty
pool is a silent fail-open. The plaintext lists get a build-time parse that fails
the rebuild on a typo; a runtime secret cannot, so the unit failing is the
substitute for that guarantee.

## Testing

- Go tests for the two handlers and the membership badge, following the existing
  `peers_test.go` patterns, including the permanent-device case where no remove
  button is rendered.
- A parse test for the MAC loader covering comments, blank lines and a malformed
  entry.
- `nix build .#nixosConfigurations.bingo.config.system.build.toplevel` as the
  gate, and bongo to confirm it is unchanged.
- Manual: `nft list set inet router-blocklists lowtrust_macs_temp` after a button
  press, and the `lowtrust_policy` rule counters after exercising a blocked port.

## Deliberately not in scope

- **VoWiFi.** UDP 500 and 4500 are already dropped for the whole LAN by
  `custom-port-blocklist.txt`, whose note records that nothing on this LAN used
  IPsec at the time. VoWiFi is IKEv2 to the carrier's ePDG on exactly those
  ports, so it cannot work over this WiFi today. Making it work is a change to a
  global rule affecting every device and belongs in its own piece of work.
- **The Akamai-fronted control channel.** The captures show the client fetching
  from unregistered names presented to real Akamai edge ranges. Nothing
  device-scoped reaches it, and Akamai cannot be blocked without breaking the
  house.
- **MAC randomisation.** Stated above as a known, unmitigated weakness.
