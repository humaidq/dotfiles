"""Convert standard VCF contacts to Nokia S30+ compatible backup.dat format."""

import sys


def parse_vcf(filename):
    """Parse VCF file and extract contacts."""
    entries = []
    name = ""
    mobile_cnt = 1
    home_cnt = 1
    work_cnt = 1

    with open(filename, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()

            if line.startswith("FN:"):
                name = line[3:]
                mobile_cnt = 1
                home_cnt = 1
                work_cnt = 1

            elif "TEL;TYPE=" in line:
                parts = line.split(":", 1)
                if len(parts) == 2:
                    type_part = parts[0]
                    phone = parts[1]
                    entry_name = name

                    if "CELL" in type_part:
                        entry_name += "_M"
                        if mobile_cnt > 1:
                            entry_name += str(mobile_cnt)
                        mobile_cnt += 1
                    elif "WORK" in type_part:
                        entry_name += "_W"
                        if work_cnt > 1:
                            entry_name += str(work_cnt)
                        work_cnt += 1
                    elif "HOME" in type_part:
                        entry_name += "_H"
                        if home_cnt > 1:
                            entry_name += str(home_cnt)
                        home_cnt += 1

                    entries.append({"name": entry_name, "phone": phone})

    return entries


def create_backup(entries):
    """Write entries to Nokia-compatible backup.dat file."""
    with open("backup.dat", "w", encoding="utf-8") as f:
        for entry in entries:
            f.write("BEGIN:VCARD\n")
            f.write("VERSION:2.1\n")
            f.write("N;ENCODING=QUOTED-PRINTABLE;CHARSET=UTF-8:;=\n")
            f.write(f"{entry['name']};;;\n")
            f.write(f"TEL;VOICE;CELL:{entry['phone']}\n")
            f.write("END:VCARD\n\n")


def main():
    """Main entry point."""
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <FILE.vcf>")
        sys.exit(1)

    entries = parse_vcf(sys.argv[1])
    create_backup(entries)
    print(f"Created backup.dat with {len(entries)} contacts")


if __name__ == "__main__":
    main()
