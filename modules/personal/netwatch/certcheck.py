"""Probe unexplained endpoints and describe their certificates.

Separate from analyse.py because this one touches the network, and keeping
the analysis pure is what makes it testable. Best-effort by design: the run
already has its report before this ever runs.

These are indicators, not proof. Ordinary applications do serve hand-made
certificates, because a pinned client has no use for a public CA, so a
flagged certificate means look closer rather than concluded.
"""

import datetime
import json
import re
import subprocess
import sys

MIN_BYTES = 100000
MAX_SANE_YEARS = 2.0
MIN_SERIAL_HEX = 8

SUBJECT_RE = re.compile(r"^subject=(.*)$", re.M)
ISSUER_RE = re.compile(r"^issuer=(.*)$", re.M)
SERIAL_RE = re.compile(r"^serial=(\S+)$", re.M)
BEFORE_RE = re.compile(r"^notBefore=(.*)$", re.M)
AFTER_RE = re.compile(r"^notAfter=(.*)$", re.M)


def _parse_date(text):
    for fmt in ("%b %d %H:%M:%S %Y %Z", "%Y-%m-%d"):
        try:
            return datetime.datetime.strptime(text.strip(), fmt)
        except ValueError:
            continue
    return None


def suspicious(cert):
    # Reasons this certificate was probably not issued by a public CA.
    reasons = []

    before = _parse_date(cert.get("not_before", ""))
    after = _parse_date(cert.get("not_after", ""))
    if before and after:
        years = (after - before).days / 365.25
        if years > MAX_SANE_YEARS:
            reasons.append("validity span {:.1f} years".format(years))

    serial = cert.get("serial", "").strip()
    if serial and len(serial) < MIN_SERIAL_HEX:
        reasons.append(
            "serial {} is too short for a public CA".format(serial))

    subject = cert.get("subject", "").strip()
    issuer = cert.get("issuer", "").strip()
    if subject and subject == issuer:
        reasons.append("issuer equals subject")

    return reasons


def targets(observations):
    # Unexplained peers carrying enough volume to be worth a probe.
    found = []
    for device in observations.get("devices", []):
        for peer in device.get("peers", []):
            if peer.get("explained"):
                continue
            if peer["bytes_out"] + peer["bytes_in"] < MIN_BYTES:
                continue
            key = (peer["ip"], peer["port"])
            if key not in found:
                found.append(key)
    return found


def fetch(ip, port, timeout=10):
    # Retrieve a certificate. Returns a dict, or None if nothing answered.
    try:
        connected = subprocess.run(
            ["openssl", "s_client", "-connect", "{}:{}".format(ip, port)],
            input=b"", capture_output=True, timeout=timeout)
        parsed = subprocess.run(
            ["openssl", "x509", "-noout", "-subject", "-issuer", "-serial",
             "-dates"],
            input=connected.stdout, capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    text = parsed.stdout.decode("utf-8", "replace")
    if "subject=" not in text:
        return None

    def grab(pattern):
        match = pattern.search(text)
        return match.group(1).strip() if match else ""

    return {
        "subject": grab(SUBJECT_RE), "issuer": grab(ISSUER_RE),
        "serial": grab(SERIAL_RE), "not_before": grab(BEFORE_RE),
        "not_after": grab(AFTER_RE),
    }


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: certcheck OBSERVATIONS_JSON REPORT_FILE\n")
        return 2
    with open(argv[1]) as handle:
        observations = json.load(handle)
    lines = []
    for ip, port in targets(observations):
        cert = fetch(ip, port)
        if cert is None:
            lines.append(
                "     {}:{} no certificate retrieved".format(ip, port))
            continue
        lines.append("     {}:{} {} (issuer {})".format(
            ip, port, cert["subject"], cert["issuer"]))
        for reason in suspicious(cert):
            lines.append("       ! {}".format(reason))
    if lines:
        with open(argv[2], "a") as handle:
            handle.write("   certificates of unexplained peers:\n")
            handle.write("\n".join(lines))
            handle.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
