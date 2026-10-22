#!/usr/bin/env python3
"""ucode_scan.py <rom> [--json]: list RSP microcode version strings and their ROM offsets.

Graphics microcode data sections carry a version string, e.g.
"RSP Gfx ucode F3DEX fifo 2.08  Yoshitaka Yasumoto 1999 Nintendo." Older ones say
"RSP SW Version: ...". Audio microcode usually carries none. A hit tells you
where a microcode's *data* sits (its text is normally just before it in ROM);
it is a hint, not proof.
"""

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import romfmt  # noqa: E402

PATTERNS = [
    rb"RSP Gfx ucode [ -~]{4,96}",
    rb"RSP SW Version[ -~]{0,96}",
    rb"RSP Audio[ -~]{0,96}",
    rb"(?<![A-Za-z])(?:F3DEX|F3DZEX|F3DLX|F3DLP|F3DFLX|L3DEX|S2DEX|S2D|Turbo3D|ZSort)[0-9A-Za-z_.]*[ -~]{0,64}",
]


def scan(rom: bytes) -> list[dict]:
    hits: dict[int, str] = {}
    for pat in PATTERNS:
        for m in re.finditer(pat, rom):
            start = m.start()
            # A later pattern matching inside an earlier hit isn't a new string.
            if any(s <= start < s + len(t) for s, t in hits.items()):
                continue
            hits[start] = m.group().decode("ascii").rstrip()
    return [{"offset": f"0x{o:X}", "text": t} for o, t in sorted(hits.items())]


def main() -> None:
    args = [a for a in sys.argv[1:] if a != "--json"]
    if len(args) != 1:
        sys.exit(__doc__.splitlines()[0])
    data = Path(args[0]).read_bytes()
    fmt = romfmt.detect(data)
    if fmt is None:
        sys.exit(f"ucode_scan.py: {args[0]} is not an N64 ROM")
    hits = scan(romfmt.to_z64(data, fmt))
    if "--json" in sys.argv:
        print(json.dumps(hits, indent=2))
        return
    if not hits:
        print("no microcode version strings found")
    for h in hits:
        print(f"{h['offset']:>10}  {h['text']}")


if __name__ == "__main__":
    main()
