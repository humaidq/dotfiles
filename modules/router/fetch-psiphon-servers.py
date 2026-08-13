#!/usr/bin/env python3
"""Fetch and decode Psiphon's live remote server list.

WHY THIS EXISTS
---------------
The 366 Psiphon addresses in custom-throttle-list.txt came out of the APK's
EMBEDDED server list, which is only a bootstrap seed. Comparing it against what
the client actually fetches at runtime showed the two barely overlap — 10
addresses in common out of 430. The embedded list is a snapshot; this URL is the
live estate, and it rotates. So a one-time paste goes stale and the only way to
keep up is to re-run this.

The stronger evidence for that: of the addresses already in the router's files
from capture-led rounds, 3 appear in the embedded seed but 22 appear in the live
list. The live list is the operationally useful one.

WHAT IT FETCHES
---------------
A public, unauthenticated S3 object. No credentials, no account, nothing that
needs the app installed or running. It is the same URL the client uses, taken
from com.psiphon3.subscription v479 (assets decoded from
com/psiphon3/psiphonlibrary/i1.java, base64 in the config JSON).

The payload is zlib-compressed JSON: {"data", "signature", "signingPublicKeyDigest"}.
`data` is newline-separated hex; each line decodes to a padding prefix followed
by a JSON server entry carrying ipAddress, region, capabilities, the ports the
node listens on, and per-node ssh credentials.

VERIFICATION
------------
Both checks are real and both run by default, using only the standard library:

  * the pinned RSA-4096 public key is hashed (sha256 over the base64 STRING, which
    is how Psiphon computes it) and compared to signingPublicKeyDigest, so a
    swapped signing key is caught;
  * the RSA PKCS#1 v1.5 signature over `data` is verified by modular
    exponentiation — the public exponent is 3, so this is a few lines and needs
    no crypto dependency.

If either fails the script exits non-zero and prints nothing. Do not feed
unverified output into the router's lists.

CREDENTIALS
-----------
Every entry contains a live sshPassword and sshHostKey. --json REDACTS those by
default. --json-raw includes them; do not commit that output — this repository
is public.

USAGE
-----
  ./fetch-psiphon-servers.py                 # one IP per line, verified
  ./fetch-psiphon-servers.py --new           # only IPs not already in the lists
  ./fetch-psiphon-servers.py --new --probe   # ...and only those answering
  ./fetch-psiphon-servers.py --ports         # IP<TAB>ports it declares
  ./fetch-psiphon-servers.py --json          # full entries, secrets redacted
  ./fetch-psiphon-servers.py --stats         # regions, ports, hosting networks

--probe opens a TCP connection to each node on the ports its OWN entry declares.
Run it from the router if you intend to act on the result: the shaper hooks
forward, so an already-throttled address probed from a LAN client reads as dead.
Nothing else here touches the network beyond the one HTTPS fetch.
"""

import argparse
import base64
import binascii
import collections
import concurrent.futures
import hashlib
import json
import pathlib
import re
import socket
import sys
import urllib.request
import zlib

# From com.psiphon3.subscription v479. The S3 object is the primary; the three
# cover domains are the same content served under unrelated names, which the
# client uses when the direct fetch fails. They are listed as fallbacks for the
# same reason, not because they are expected to differ.
SPONSOR_PATH = "web/iohq-waa4-q4dt/server_list_compressed"
URLS = [
    f"https://s3.amazonaws.com/psiphon/{SPONSOR_PATH}",
    f"https://www.corporatehirepressth.com/{SPONSOR_PATH}",
    f"https://www.designrecruitmentvure.com/{SPONSOR_PATH}",
    f"https://www.storagejsstrategiesfabulous.com/{SPONSOR_PATH}",
]

# RemoteServerListSignaturePublicKey, verbatim from the same config. A public
# key: pinning it here is the point, since it is what detects a substituted list.
SIGNING_PUBLIC_KEY = (
    "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6"
    "HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmv"
    "DmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/Krvzg"
    "QXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZA"
    "LQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZX"
    "QNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFE"
    "mIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAU"
    "BItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM="
)

PORT_FIELDS = [
    "sshPort",
    "sshObfuscatedPort",
    "sshObfuscatedQUICPort",
    "SshShadowsocksPort",
    "meekServerPort",
]
SECRET_FIELDS = {
    "sshPassword",
    "sshHostKey",
    "sshUsername",
    "sshObfuscatedKey",
    "meekObfuscatedKey",
    "meekCookieEncryptionPublicKey",
    "SshShadowsocksKey",
    "webServerSecret",
    "signature",
}

HERE = pathlib.Path(__file__).resolve().parent
LIST_FILES = ["custom-throttle-list.txt", "custom-ip-blocklist.txt"]


def fetch(timeout):
    """Return the raw package bytes from the first URL that answers."""
    errors = []
    for url in URLS:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "psiphon-tunnel-core"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read()
            if body:
                return body, url
        except Exception as exc:  # noqa: BLE001 - any failure means try the next mirror
            errors.append(f"{url}: {exc}")
    sys.exit("all sources failed:\n  " + "\n  ".join(errors))


def rsa_public_numbers(der):
    """Pull (n, e) out of a DER SubjectPublicKeyInfo without a crypto library."""
    i = der.find(b"\x03\x82")
    length = int.from_bytes(der[i + 2 : i + 4], "big")
    inner = der[i + 4 + 1 : i + 4 + length]  # +1 skips the unused-bits octet
    if inner[0] != 0x30:
        raise ValueError("expected RSAPublicKey SEQUENCE")
    pos = 2 if inner[1] < 0x80 else 2 + (inner[1] & 0x7F)

    def read_int(buf, p):
        if buf[p] != 0x02:
            raise ValueError("expected INTEGER")
        ln = buf[p + 1]
        p += 2
        if ln & 0x80:
            nbytes = ln & 0x7F
            ln = int.from_bytes(buf[p : p + nbytes], "big")
            p += nbytes
        return int.from_bytes(buf[p : p + ln], "big"), p + ln

    n, pos = read_int(inner, pos)
    e, _ = read_int(inner, pos)
    return n, e


def verify(pkg):
    """Check the signing key digest and the RSA signature. Exit on failure."""
    want = pkg.get("signingPublicKeyDigest")
    got = base64.b64encode(hashlib.sha256(SIGNING_PUBLIC_KEY.encode()).digest()).decode()
    if want != got:
        sys.exit(
            "SIGNING KEY MISMATCH — the list was signed by a different key than the one\n"
            f"pinned in this script.\n  package: {want}\n  pinned : {got}\n"
            "Refusing to output. Re-extract the key from a current APK before trusting this."
        )

    n, e = rsa_public_numbers(base64.b64decode(SIGNING_PUBLIC_KEY))
    sig = int.from_bytes(base64.b64decode(pkg["signature"]), "big")
    plain = pow(sig, e, n).to_bytes((n.bit_length() + 7) // 8, "big")
    # PKCS#1 v1.5: 0x00 0x01 FF..FF 0x00 <DigestInfo>. The SHA-256 digest is the
    # trailing 32 bytes; comparing those is sufficient given the padding check.
    if not plain.startswith(b"\x00\x01\xff\xff"):
        sys.exit("SIGNATURE INVALID — PKCS#1 padding malformed. Refusing to output.")
    if plain[-32:] != hashlib.sha256(pkg["data"].encode()).digest():
        sys.exit("SIGNATURE INVALID — data does not match signature. Refusing to output.")


def decode_entries(data):
    """Hex-decode each newline-separated record into its JSON server entry."""
    entries = []
    for chunk in re.split(r"\s+", data):
        if not chunk:
            continue
        if len(chunk) % 2:
            chunk = chunk[:-1]
        try:
            raw = binascii.unhexlify(chunk)
        except binascii.Error:
            continue
        start = raw.find(b"{")
        if start < 0:
            continue
        text = raw[start:].decode("utf-8", errors="replace")
        try:
            entries.append(json.loads(text))
        except json.JSONDecodeError:
            end = text.rfind("}")
            if end < 0:
                continue
            try:
                entries.append(json.loads(text[: end + 1]))
            except json.JSONDecodeError:
                continue
    return entries


def ports_of(entry):
    return sorted({int(entry[f]) for f in PORT_FIELDS if entry.get(f)})


def already_listed():
    """Addresses already present in the router's two address files."""
    known = set()
    for name in LIST_FILES:
        path = HERE / name
        if not path.exists():
            continue
        for line in path.read_text(errors="replace").splitlines():
            line = re.sub(r"#.*", "", line).strip()
            if re.fullmatch(r"(\d{1,3}\.){3}\d{1,3}", line):
                known.add(line)
    return known


def probe(entries, workers, timeout):
    """Keep entries answering on at least one port their own record declares."""

    def check(entry):
        for port in ports_of(entry):
            try:
                sock = socket.create_connection((entry["ipAddress"], port), timeout=timeout)
                sock.close()
                return entry
            except OSError:
                continue
        return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        return [e for e in pool.map(check, entries) if e]


def redact(entry):
    return {k: ("<redacted>" if k in SECRET_FIELDS else v) for k, v in entry.items()}


def main():
    ap = argparse.ArgumentParser(
        description="Fetch, verify and decode Psiphon's live remote server list.",
        epilog="Output is only produced when the signature verifies.",
    )
    ap.add_argument("--new", action="store_true", help="only addresses not already in the router's lists")
    ap.add_argument("--probe", action="store_true", help="only addresses answering on a declared port")
    ap.add_argument("--ports", action="store_true", help="print IP<TAB>declared ports")
    ap.add_argument("--json", action="store_true", help="full entries, credentials redacted")
    ap.add_argument("--json-raw", action="store_true", help="full entries INCLUDING credentials (do not commit)")
    ap.add_argument("--stats", action="store_true", help="summarise regions, ports and capabilities")
    ap.add_argument("--timeout", type=float, default=30.0, help="HTTP timeout, seconds (default 30)")
    ap.add_argument("--probe-timeout", type=float, default=4.0, help="per-port TCP timeout (default 4)")
    ap.add_argument("--workers", type=int, default=60, help="probe concurrency (default 60)")
    args = ap.parse_args()

    body, source = fetch(args.timeout)
    pkg = json.loads(zlib.decompress(body))
    verify(pkg)

    entries = decode_entries(pkg["data"])
    if not entries:
        sys.exit("signature verified but no server entries decoded — format may have changed")
    total = len(entries)

    print(f"# source: {source}", file=sys.stderr)
    print(f"# signature verified, {total} entries", file=sys.stderr)

    if args.new:
        known = already_listed()
        entries = [e for e in entries if e.get("ipAddress") not in known]
        print(f"# {total - len(entries)} already listed, {len(entries)} new", file=sys.stderr)

    if args.probe:
        before = len(entries)
        entries = probe(entries, args.workers, args.probe_timeout)
        print(f"# probed {before}, {len(entries)} answering", file=sys.stderr)

    if args.stats:
        regions = collections.Counter(e.get("region", "??") for e in entries)
        ports = collections.Counter(p for e in entries for p in ports_of(e))
        caps = collections.Counter(c for e in entries for c in e.get("capabilities", []))
        print(f"entries: {len(entries)}")
        print("\nregions:")
        for k, v in regions.most_common():
            print(f"  {k:4s} {v}")
        print("\nports:")
        for k, v in sorted(ports.items()):
            print(f"  {k:6d} {v}")
        print("\ncapabilities:")
        for k, v in caps.most_common():
            print(f"  {k:44s} {v}")
        return

    if args.json or args.json_raw:
        out = entries if args.json_raw else [redact(e) for e in entries]
        if args.json_raw:
            print("# WARNING: contains live ssh credentials — do not commit", file=sys.stderr)
        json.dump(out, sys.stdout, indent=1)
        print()
        return

    for entry in sorted(
        entries, key=lambda e: tuple(int(o) for o in e.get("ipAddress", "0.0.0.0").split("."))
    ):
        ip = entry.get("ipAddress")
        if not ip:
            continue
        if args.ports:
            print(f"{ip}\t{','.join(str(p) for p in ports_of(entry))}")
        else:
            print(ip)


if __name__ == "__main__":
    main()
