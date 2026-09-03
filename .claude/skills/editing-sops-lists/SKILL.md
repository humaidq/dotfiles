---
name: editing-sops-lists
description: Use when reading, editing, grepping or re-keying the encrypted router lists in secrets/router/ (blocklists, throttle lists, ASN lists, the DNS common-domains list), when a `grep` over the repo stops finding a domain or address it used to find, or when adding a host key to .sops.yaml
---

# Editing the sops router lists

## Overview

Every filter list the router reads lives in `secrets/router/*.txt`, encrypted
with sops. They moved there from `modules/router/` on 2026-09-03 because 55-68%
of their lines are comments and the comments are per-person monitoring detail —
this repository is public.

**Use `.claude/skills/editing-sops-lists/lists.sh` rather than sops directly.**
It knows the naming, the creation-rule trap, and the unit that has to restart.

```bash
L=.claude/skills/editing-sops-lists/lists.sh
$L ls                          # what exists, line counts, checkout state
$L grep aquuuacasino           # search every list — plain grep finds nothing
$L cat throttle | head         # decrypt one to stdout
$L edit blocklist              # $EDITOR, re-encrypted on save
```

Names are forgiving: `blocklist`, `custom-blocklist` and `custom-blocklist.txt`
all resolve to the same file.

## The thing that will catch you first

**`grep -r` over this repository no longer finds addresses or domains.** They
are ciphertext. Every habit built on `grep modules/router/` is dead, and the
failure is silent — you get no hits and conclude the entry is absent, which is
exactly backwards.

`$L grep` is the replacement. It decrypts each list and greps the plaintext,
prefixing hits with the file name and line number.

## Editing one or two lines

`$L edit <name>`. sops decrypts to a temp file, opens `$EDITOR`, re-encrypts on
save, and never writes plaintext to the repository.

**Then restart the unit that reads it**, because a rebuild is no longer what
applies a list change:

| List | Restart |
|---|---|
| `custom-blocklist`, `custom-whitelist` | `blocky.service` |
| `custom-imo-list` | `imo-policy.service` |
| `custom-lowtrust-stun-hosts` | `nft-lowtrust-stun.service` |
| `custom-lowtrust-allow-domains` | `nft-lowtrust-allow-domains.service` |
| everything else in the nft path | `nft-blocklists-local.service` |
| `dns-common-domains` | nothing — only this skill set reads it |

`modules/router/lists.nix` is the authority on that mapping; each secret's
`restartUnits` is the same table. On a `nixos-rebuild switch` sops-nix does the
restart for you when the decrypted content changed. Editing a list on the
router without a rebuild does not, hence the table.

## Bulk work — regenerating a list from a script

`fetch-v2ray-nodes.py` and `fetch-psiphon-servers.py` want real files on disk
and read sibling lists to deduplicate against. Give them a checkout:

```bash
$L checkout                     # decrypts all of them into .lists-work/
python3 modules/router/fetch-v2ray-nodes.py    # point it at .lists-work
$L diff                         # read every change before it goes back
$L commit                       # re-encrypt only what changed
$L discard                      # delete the plaintext when done
```

`.lists-work/` is added to `.gitignore` on first checkout and chmod'd `go-rwx`.
**`discard` when you are finished.** A forgotten checkout is a plaintext copy of
everything this migration existed to encrypt, sitting in the repository root.

`$L ls` flags a dirty checkout, so run it before you start work you think is
fresh.

## Adding a host key

Edit `.sops.yaml`, then **rewrite every affected file** or the new host cannot
decrypt anything:

```bash
$L rotate      # sops updatekeys over all of secrets/router/
```

Files outside `secrets/router/` need `sops updatekeys secrets/<file>.yaml`
individually — `rotate` deliberately only touches this directory.

## The creation-rule trap

sops matches `creation_rules` against **the path of the file it is encrypting**,
not where you redirect the output. So this fails with
`no matching creation rules found`:

```bash
sops -e modules/router/list.txt > secrets/router/list.txt   # WRONG
```

Copy first, encrypt in place second:

```bash
cp modules/router/list.txt secrets/router/list.txt
sops --encrypt --in-place secrets/router/list.txt
```

`$L commit` does it this way. This is the single most likely reason a new list
refuses to encrypt.

## Adding a new list

1. Create the plaintext, `cp` it into `secrets/router/`, `sops -e -i` it.
2. Add an entry to `lists` in `modules/router/lists.nix` — `file` and the
   `units` that must restart. Add `mode = "0444"` if the reader runs under
   `DynamicUser` (blocky and router-web both do; they have no uid to own a
   file).
3. Consume it as `cfg.lists.<name>` — never `${./whatever.txt}`, which puts it
   back in the public store.
4. `nix build --no-link .#nixosConfigurations.bongo.config.system.build.toplevel`

A list declared in `lists.nix` with an empty `units` is fine (`inspectedApps`
is), but a list with the *wrong* unit is an edit that silently does nothing.

## Verify before claiming done

```bash
# round-trips to exactly what you meant
$L cat <name> | diff - /path/to/what/you/edited

# both routers still build — this is the real gate
nix build --no-link \
  .#nixosConfigurations.bongo.config.system.build.toplevel \
  .#nixosConfigurations.bingo.config.system.build.toplevel

# no plaintext left behind
$L ls | grep -i modified ; ls .lists-work 2>/dev/null
```

Do **not** run `nix flake check` — it builds every host and takes about an hour.

## Common mistakes

| Mistake | Reality |
|---|---|
| `grep -r 1.2.3.4 modules/` finds nothing, so it isn't listed | It is ciphertext now. Use `$L grep`. |
| `sops -e file > secrets/router/file` | Creation rules match the input path. `cp` then `-i`. |
| Edited a list, called it applied | A rebuild no longer rewrites the unit. Restart what the table above names. |
| Left `.lists-work/` behind | Plaintext copy of every list, in the repo root. `$L discard`. |
| Added a list with `${./file.txt}` | Straight back into the public Nix store. Use `cfg.lists.<name>`. |
| Added a host to `.sops.yaml` and stopped | Without `updatekeys` the host decrypts nothing and fails at activation. |
| Assumed encryption hides past versions | It does not. Everything committed before 2026-09-03 is still in the public history. |

## What this did not fix

The plaintext lists are in the git history of a public repository, and every
version of them is still there. Encrypting from here stops new detail leaking;
it does not retract what is already published. Rewriting that history is a
separate decision with its own costs (every clone breaks, forks and caches keep
copies anyway).
