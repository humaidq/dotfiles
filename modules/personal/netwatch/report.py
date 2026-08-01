"""Render one run's observations as text.

Written to be read by something else — a person, or a model handed the day's
file. That is why it states counts, shares and certificate fields rather than
adjectives: the next stage needs evidence, and anything guessed here would have
to be un-guessed before it could be trusted.
"""

import datetime
import json
import sys

TOP_PEERS_SHOWN = 8


def _stamp(ts):
    return datetime.datetime.fromtimestamp(
        ts, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")


def render(observations):
    lines = []
    lines.append("=" * 72)
    lines.append("netwatch run {}".format(_stamp(observations["run_ts"])))

    if not observations.get("captured"):
        lines.append("RUN SKIPPED: {}".format(
            observations.get("skip_reason") or "unknown reason"))
        lines.append("")
        return "\n".join(lines)

    for device in observations["devices"]:
        total = device["total_bytes"]
        lines.append("")
        lines.append("-- {} ({})".format(device["label"], device["mac"]))
        lines.append("   {} bytes across {} peers".format(
            total, device["peer_count"]))

        novelty = device.get("novelty", {})
        lines.append("   blocked answers: {}".format(
            novelty.get("blocked_count", 0)))

        if device["observations"]:
            lines.append("   observations:")
            for obs in device["observations"]:
                lines.append("     [{}] {}: {}".format(
                    obs["severity"], obs["check"], obs["detail"]))

        if device["peers"]:
            lines.append("   top peers:")
            for peer in device["peers"][:TOP_PEERS_SHOWN]:
                volume = peer["bytes_out"] + peer["bytes_in"]
                share = (volume / total * 100) if total else 0.0
                tag = "" if peer.get("explained") else "  no-dns"
                name = peer.get("resolved_name") or peer.get("sni") or ""
                lines.append("     {:>9} {:>6.1f}%  {}:{}/{} {}{}".format(
                    volume, share, peer["ip"], peer["port"],
                    peer["proto"], name, tag))

    lines.append("")
    return "\n".join(lines)


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: report OBSERVATIONS_JSON REPORT_FILE\n")
        return 2
    with open(argv[1]) as handle:
        observations = json.load(handle)
    with open(argv[2], "a") as handle:
        handle.write(render(observations))
        handle.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
