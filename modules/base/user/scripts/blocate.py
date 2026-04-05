import subprocess
import json
import sys
import requests
import re


###############################################################################
# Low-level parsing of nmcli -t output
###############################################################################


def split_nmcli_line(line):
    r"""
    nmcli -t uses ':' as delimiter, but escapes literal ':' in fields as '\:'.
    It also escapes '\' as '\\'.

    This walks the line char-by-char and splits only on unescaped ':'.
    Returns list of decoded fields with escapes removed.
    """
    fields = []
    buf = []
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "\\":
            # escape: take next char literally if it exists
            i += 1
            if i < len(line):
                buf.append(line[i])
        elif ch == ":":
            # real field separator
            fields.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
        i += 1
    # last field
    fields.append("".join(buf))
    return fields


def nmcli_scan():
    """
    Run `nmcli` to list nearby WiFi APs.
    Returns a list of dicts:
    [
      {
        "bssid": "aa:bb:cc:dd:ee:ff",
        "ssid": "SomeSSID",
        "freq": "2437",
        "chan": "6",
        "signal": "75",
      },
      ...
    ]
    """
    cmd = [
        "nmcli",
        "-t",
        "-f",
        "BSSID,SSID,FREQ,CHAN,SIGNAL",
        "device",
        "wifi",
        "list",
        "--rescan",
        "yes",
    ]

    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError as e:
        print("Failed to run nmcli. Are you using NetworkManager?",
              file=sys.stderr)
        raise e

    lines = out.decode("utf-8", errors="replace").strip().split("\n")

    aps = []
    for line in lines:
        if not line.strip():
            continue

        parts = split_nmcli_line(line)
        # Expect exactly 5 fields after correct splitting:
        # [BSSID, SSID, FREQ, CHAN, SIGNAL]
        if len(parts) < 5:
            continue

        bssid = parts[0].strip()
        ssid = parts[1].strip()
        freq = parts[2].strip()
        chan = parts[3].strip()
        signal = parts[4].strip()

        # freq sometimes like "2437 MHz", strip non-digits
        m = re.match(r"^(\d+)", freq)
        if m:
            freq = m.group(1)

        aps.append(
            {
                "bssid": bssid,
                "ssid": ssid,
                "freq": freq if freq and freq != "--" else None,
                "chan": chan if chan and chan != "--" else None,
                "signal": signal if signal and signal != "--" else None,
            }
        )

    return aps


###############################################################################
# BeaconDB payload helpers
###############################################################################


def is_locally_administered_mac(mac):
    """
    True if MAC is locally-administered/randomised (we skip those).
    """
    m = mac.split(":")
    if len(m) != 6:
        return True  # malformed, drop it
    try:
        first_octet = int(m[0], 16)
    except ValueError:
        return True
    # LAA bit set? (bit 1 of first octet)
    return (first_octet & 0x02) != 0


def approx_dbm_from_percent(pct_str):
    """
    Rough map 0-100% quality -> RSSI dBm.
    dBm ≈ (pct/2) - 100
    """
    if pct_str is None:
        return None
    try:
        pct = int(pct_str)
    except ValueError:
        return None
    return int(round(pct / 2.0 - 100))


def should_skip_ap(ap):
    """
    Filter APs we shouldn't send:
    - malformed MAC
    - locally-administered MAC
    - hidden SSID or *_nomap
    """
    bssid = ap["bssid"]
    ssid = ap["ssid"]

    if not re.match(r"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", bssid):
        return True

    if is_locally_administered_mac(bssid):
        return True

    if ssid == "" or ssid is None:
        return True

    if ssid.endswith("_nomap"):
        return True

    return False


def build_payload(aps):
    """
    Convert scan to BeaconDB/MLS geolocate payload.
    """
    wifi_list = []

    for ap in aps:
        if should_skip_ap(ap):
            continue

        entry = {
            "macAddress": ap["bssid"].lower(),
            "age": 0,
        }

        dbm = approx_dbm_from_percent(ap["signal"])
        if dbm is not None:
            entry["signalStrength"] = dbm

        if ap["chan"] and ap["chan"].isdigit():
            entry["channel"] = int(ap["chan"])

        if ap["freq"] and ap["freq"].isdigit():
            entry["frequency"] = int(ap["freq"])

        wifi_list.append(entry)

    payload = {
        "wifiAccessPoints": wifi_list,
    }

    return payload


def geolocate(payload):
    """
    POST payload to BeaconDB.
    """
    url = "https://api.beacondb.net/v1/geolocate"

    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
    }

    r = requests.post(url, headers=headers, data=json.dumps(payload),
                      timeout=10)

    if r.status_code == 200:
        return r.json()

    try:
        return {"error": True, "status": r.status_code, "body": r.json()}
    except Exception:
        return {"error": True, "status": r.status_code, "body": r.text}


###############################################################################
# Maidenhead grid conversion
###############################################################################


def maidenhead(lat, lon):
    """
    Convert lat/lon (in degrees) to a 6-character Maidenhead locator,
    e.g. 'LL75sj'.

    Algorithm:
    1. Shift lon by +180, lat by +90 so they're positive.
    2. First pair (A-R): 20° lon blocks, 10° lat blocks.
    3. Second pair (0-9): 2° lon blocks, 1° lat blocks.
    4. Third pair (a-x): 5' lon (~0.083333°), 2.5' lat (~0.0416667°).
    """
    lon_shift = lon + 180.0
    lat_shift = lat + 90.0

    upper = "ABCDEFGHIJKLMNOPQR"  # 18 letters
    lower = "abcdefghijklmnopqrstuvwx"  # 24 letters

    # Field (2 letters)
    field_lon = int(lon_shift // 20)
    field_lat = int(lat_shift // 10)

    # Square (2 digits)
    square_lon = int((lon_shift % 20) // 2)
    square_lat = int((lat_shift % 10) // 1)

    # Subsquare (2 letters, lowercase)
    subsquare_lon = int(((lon_shift % 2) / 2.0) * 24)
    subsquare_lat = int(((lat_shift % 1) / 1.0) * 24)

    locator = (
        upper[field_lon]
        + upper[field_lat]
        + str(square_lon)
        + str(square_lat)
        + lower[subsquare_lon]
        + lower[subsquare_lat]
    )

    return locator


###############################################################################
# Main
###############################################################################


def main():
    aps = nmcli_scan()

    if not aps:
        print("No WiFi data from nmcli, can't continue.", file=sys.stderr)
        sys.exit(1)

    payload = build_payload(aps)

    if len(payload["wifiAccessPoints"]) == 0:
        print("After filtering, no APs were considered valid.")
        print("Raw scan for debugging:")
        print(json.dumps(aps, indent=2))
        sys.exit(2)

    if len(payload["wifiAccessPoints"]) < 2:
        print(
            "Warning: <2 APs after filtering, WiFi-based fix may fail.\n",
            file=sys.stderr,
        )

    resp = geolocate(payload)

    if "error" in resp and resp["error"]:
        print("BeaconDB lookup failed:")
        print(json.dumps(resp, indent=2))
        sys.exit(3)

    loc = resp.get("location", {})
    acc = resp.get("accuracy")

    lat = loc.get("lat")
    lng = loc.get("lng")

    if lat is None or lng is None:
        print("BeaconDB response didn't include coordinates:")
        print(json.dumps(resp, indent=2))
        sys.exit(4)

    grid = maidenhead(lat, lng)

    print("Estimated position:")
    print(f"  latitude : {lat}")
    print(f"  longitude: {lng}")
    if acc is not None:
        print(f"  accuracy : ±{acc} m")
    print(f"  grid     : {grid}")

    print("\nMap link:")
    print(f"https://www.google.com/maps/place/{lat},{lng}")


if __name__ == "__main__":
    main()
