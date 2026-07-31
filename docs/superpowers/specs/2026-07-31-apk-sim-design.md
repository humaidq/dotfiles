# Runtime traffic capture for the app-blocking skill — design

Date: 2026-07-31
Status: Approved, ready for implementation plan

## Problem

The `blocking-apps-by-domain` skill finds an app's backend domains by pulling
string tables out of its APK. That works well when the domains are in the
package, and not at all when they are not. `SKILL.md` already documents four
ways the static approach dead-ends:

- **PAIR-wrapped packages** (ZaffaLive) — Google Play's integrity wrapper
  encrypts the payload; nothing is recoverable.
- **Packed dex** (Chamet, MateMet ship ~74 KiB stubs alongside
  `libplt-base.so`) — code, manifest and resources are all stripped.
- **Runtime-assembled config** (Chato) — a 37 MB dex containing only SDK
  strings, because the API base is fetched or built at runtime.
- **Runtime domain rotation** (Olamet) — the app fetches a fresh backend pool
  from `tools.hulekeji.com` whenever the current one stops resolving.

In each case the fallback today is "use brand domains and watch blocky's query
log", which is slow, imprecise, and depends on somebody in the house actually
running the app.

Running the app under observation answers the question directly. A hostname the
app dialled is stronger evidence than a hostname found in a string table, and it
survives obfuscation, packing and runtime assembly.

## Goals

1. Given an Android package name, produce the list of hosts the app actually
   contacts on first launch, on stdout, one per line, pipeable into
   `check-domains.sh`.
2. Surface the two things static extraction cannot see at all: hosts assembled
   or fetched at runtime, and **connections to hardcoded IP addresses with no
   preceding DNS lookup** — the HTTPDNS bypass that `SKILL.md` notes only an
   nftables rule can stop.
3. Run unattended. One command, no interaction.
4. Report failure as failure. An empty result must never be presentable as
   "the app contacts nothing".

## Non-goals (YAGNI)

- **No TLS interception.** The skill needs domain names, not payloads. Passive
  DNS + SNI capture yields the same answer and is immune to certificate
  pinning, which these apps use heavily.
- **No login automation.** These apps sit behind a phone-number/OTP wall. The
  script stops there by design; see "Limits" below.
- **No interactive mode.** Not in v1. If manual tap-through turns out to be
  worth it for specific apps, it can be added later as a flag.
- **No flake changes.** The emulator is a disposable investigation tool, not
  part of any host's configuration. Nothing here should enter
  `nix flake check`'s blast radius.
- **No diff-against-static mode.** `diff <(apk-domains.sh X) <(apk-sim.sh X)`
  is already available to the caller.

## Key facts established during design

- **nixpkgs packages the Android emulator**, patched to run on NixOS:
  `androidenv.androidPkgs.emulator` is `android-sdk-emulator-36.5.11`. This
  removes the need for an `sdkmanager` bootstrap or a `steam-run`/FHS wrapper,
  which was the main risk in putting this on NixOS at all.
- **System images are packaged too**, `google_apis` and `google_apis_playstore`
  for x86_64 and arm64-v8a, API 33 through 36.
- **API 34 `google_apis` x86_64 includes `ndk_translation`**, so arm64-only
  native libraries load. It ships Play Services but not the Play Store, which
  is what these apps need and more than they need to reach their API.
- **The emulator has a built-in `-tcpdump <file>` flag**, so capture requires no
  host-side interface plumbing.
- **`adb shell cmd package resolve-activity --brief <pkg>`** resolves the
  launcher activity without `aapt2`, keeping the tool dependency list to
  `android-tools` and `wireshark-cli`.
- anoa has `/dev/kvm`, 8 cores and 30 GB RAM.

## Design

A third script, `apk-sim.sh`, in
`.claude/skills/blocking-apps-by-domain/`. It follows the conventions of the
two scripts already there: `set -euo pipefail`, a comment header showing usage
and the `nix shell` line, diagnostics on stderr, results on stdout.

### Interface

```bash
nix shell nixpkgs#android-tools nixpkgs#wireshark-cli

./apk-sim.sh com.olamet.mobile | tee /tmp/live.txt
./apk-sim.sh -l ./some.apk                       # local file
./apk-sim.sh -t 240 com.foo.bar                  # longer capture window
./apk-sim.sh -d 10.10.0.16 com.foo.bar           # bongo over Nebula
```

| Flag | Default | Meaning |
|---|---|---|
| `-l <file.apk>` | — | use a local APK instead of downloading |
| `-t <seconds>` | `120` | total capture window |
| `-d <resolver>` | `10.20.0.1` | DNS server handed to the guest |

The APK cache is shared with `apk-domains.sh`
(`${TMPDIR:-/tmp}/apk-domains/<pkg>/app.apk`), fetched the same way from
APKPure if absent. Running both tools on one package costs one download.

### Component 1 — SDK provisioning

On first run the script writes a small Nix expression to
`${XDG_CACHE_HOME:-$HOME/.cache}/apk-sim/sdk.nix` and builds it, symlinking the
result to `$CACHE/sdk`:

```nix
(import (builtins.getFlake "nixpkgs").outPath {
  config.allowUnfree = true;
  config.android_sdk.accept_license = true;
}).androidenv.composeAndroidPackages {
  platformVersions = [ "34" ];
  abiVersions = [ "x86_64" ];
  systemImageTypes = [ "google_apis" ];
  includeSystemImages = true;
  includeEmulator = true;
}
```

Built with `nix build --impure` (required by `getFlake` and the license
acceptance). The nixpkgs revision comes from the flake registry, so the SDK is
pinned in practice while the expression stays inside the script — no repo
footprint, nothing for `nix flake check` to evaluate.

Interface: `$CACHE/sdk/libexec/android-sdk` is a complete `ANDROID_SDK_ROOT`
containing `emulator/`, `platform-tools/`, `cmdline-tools/` and
`system-images/`. Everything downstream depends only on that path.

### Component 2 — AVD lifecycle

One AVD named `apk-sim`, created once in `$CACHE/avd` via `avdmanager`, with
`config.ini` patched for `hw.gpu.mode=swiftshader_indirect`, sufficient RAM and
`hw.keyboard=yes`. It is booted once to completion to write a **golden
snapshot**.

Every subsequent run launches from that snapshot with `-read-only
-no-snapshot-save`. This gives a clean device per app — no residue from the
previous app's run — at roughly five seconds of start-up instead of a full
boot, and without re-provisioning.

Interface: `ensure_avd` guarantees a bootable snapshot exists and returns; the
run stage assumes nothing else about device state.

### Component 3 — capture and drive

```
emulator -avd apk-sim -no-window -no-audio -no-boot-anim \
         -gpu swiftshader_indirect -read-only -no-snapshot-save \
         -dns-server "$resolver" -tcpdump "$work/cap.pcap"
```

The resolver defaults to the router. Blocked names therefore answer `0.0.0.0`
and the app's failover logic fires naturally, which is the behaviour worth
observing — an app that rotates domains only reveals its rotation service when
its primaries stop working. The consequence to be aware of: these queries land
in blocky's query log attributed to anoa's IP.

Drive sequence, once `sys.boot_completed` is `1`:

1. `adb install -r -g "$apk"` — `-g` grants runtime permissions up front so no
   permission dialog blocks the launch.
2. Resolve the launcher activity with
   `adb shell cmd package resolve-activity --brief`, then `am start` it.
3. `adb shell monkey -p <pkg> --ignore-crashes --ignore-timeouts
   --throttle 200 -s 42 300` — seeded, so two runs of the same app take the
   same path through the UI.
4. Idle for the remainder of the capture window, so late timers and retries
   are recorded.
5. `adb emu kill`.

### Component 4 — parse and report

Four `tshark` passes over the pcap. Results are unioned, tagged by how they
were seen, and sorted:

| Tag | Extraction | Meaning |
|---|---|---|
| `SNI` | `tls.handshake.extensions_server_name` | the app opened a TLS connection to this host — the strongest signal available |
| `DNS` | `dns.qry.name` where `dns.flags.response == 0` | looked up but never connected: a backup pool member, or blocked |
| `HOST` | `http.host` on `http.request` | cleartext HTTP; frequently the rotation or config service |
| `IP` | outbound TCP SYN or QUIC to an address that appears in no A/AAAA answer in the same capture | **hardcoded resolver or origin** — invisible to every other method |

The `IP` set is computed as (destination addresses of outbound connection
initiations) minus (all addresses appearing in DNS answers in the same pcap).

The `noise` regex from `apk-domains.sh` is reused here **only to annotate**,
appending e.g. `[noise:agora]`. Nothing is dropped. `SKILL.md` already
documents that the static noise filter hides an app's escape hatches —
SoulChill's CloudFront mirrors, Gemgala's `httpdns.baidubce.com` — and a host
the app was observed dialling is worth seeing whichever zone it sits in.

Output split follows `apk-domains.sh`: the annotated table goes to stderr for
reading, the bare hostname list to stdout for `| check-domains.sh`. `IP`
entries appear in the stderr table only, since they are not names and
`check-domains.sh` cannot classify them.

### Component 5 — failure reporting

Silence must not read as a clean result. Distinguished cases:

- `INSTALL_FAILED_NO_MATCHING_ABIS` → the APK is armeabi-v7a only; the image's
  translation layer is arm64-only. Reported as an ABI mismatch, not a finding.
- The package's process is absent from `adb shell pidof` shortly after launch,
  or `logcat` shows it dying → reported as **probable emulator detection**. The
  domain list from such a run is explicitly labelled unreliable.
- Zero packets in the pcap → the capture path is broken, not the app quiet.
  Hard error.
- `monkey` reporting the package has no launchable activity → hard error.

## Risk: the capture path

On API 30+ the emulator exposes a Wi-Fi interface (`wlan0`) in addition to the
slirp-backed cellular path, and `-tcpdump` has historically recorded only the
latter. If guest traffic prefers `wlan0`, the pcap will be empty or partial.

Known mitigation: launch with `-feature -Wifi`, which removes the Wi-Fi
interface and forces all traffic onto the captured path.

**This is the first implementation step.** Boot the AVD, drive any app with
known network activity, and confirm the pcap contains its DNS queries and TLS
handshakes before writing anything downstream. If neither the default nor
`-feature -Wifi` produces a usable capture, fall back in this order:

1. `adb shell tcpdump` inside the guest, pulling the file afterwards.
2. Host-side `tcpdump` on the emulator's tap interface.

The parse stage consumes a pcap and does not care which of these produced it,
so the fallback is contained to component 3.

## Verification

No unit tests. The two existing scripts have none, and the system under test is
an emulator; a mock would verify nothing that matters.

Verification is empirical rediscovery: run the tool against packages whose
backends are already established in `custom-blocklist.txt` and confirm it finds
them independently.

- `com.olamet.mobile` must surface `tools.hulekeji.com` — a runtime rotation
  service, which is the case static extraction handles worst.
- `com.live.soulchill` must surface its `d*.cloudfront.net` mirrors.
- A packed package — Chamet or MateMet, both of which ship a ~74 KiB dex stub —
  should yield hosts where `apk-domains.sh` yields nothing. This is the whole
  justification for the tool.

If it cannot rediscover known answers, it does not work, regardless of how much
output it produces.

## Limits, to be stated in every write-up based on this tool

- **It stops at the login wall.** Apps require phone/OTP signup. Captured
  traffic covers splash, config fetch, API handshake and rotation — the layer
  the blocklist targets — but not post-login media CDNs or RTC backends. Those
  still need the static string table or the query log.
- **Emulator detection is real** and some apps will refuse to run.
- **A run is one path through the UI.** A seeded monkey is reproducible, not
  exhaustive.

The tool is therefore complementary to `apk-domains.sh`, not a replacement.
Best coverage comes from running both and taking the union.

## SKILL.md changes

1. New step after extraction: if the dex yields nothing, or the app is packed,
   PAIR-wrapped, or rotating domains, run `apk-sim.sh`.
2. Amend "When the package downloads but yields nothing" — the runtime capture
   is now the first fallback, ahead of the store listing's privacy-policy URL.
3. Amend "Missing an HTTPDNS bypass" — `apk-sim.sh`'s `IP` tag detects the
   hardcoded-resolver case directly rather than by grepping raw strings.
4. New short section recording the limits above, so write-ups based on a
   runtime run declare their coverage honestly, in the same way the skill
   already requires for brand-only entries.
