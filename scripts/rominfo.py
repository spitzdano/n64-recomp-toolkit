#!/usr/bin/env python3
"""rominfo.py: print what the toolkit needs to know about an N64 ROM.

    rominfo.py <rom>          human-readable
    rominfo.py <rom> --json   machine-readable (no ROM bytes, only header fields and hashes)

The CIC and the real entry point come from splat's own ROM-info code
(splat.util.n64.rominfo), not from a table kept here: some CICs load code at
an address that differs from the header's (6103: -0x100000, 6106: -0x200000).
"""

import argparse
import hashlib
import json
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import romfmt  # noqa: E402

romfmt.ensure_toolkit_venv()

from splat.util.n64 import rominfo as splat_rominfo  # noqa: E402

COMPRESSION_MAGICS = (b"Yaz0", b"Yay0", b"MIO0")


def inspect(path: Path) -> dict:
    raw = path.read_bytes()
    fmt = romfmt.detect(raw)
    if fmt is None:
        sys.exit(f"{path}: first four bytes {raw[:4].hex()} are not an N64 ROM magic")
    rom = romfmt.to_z64(raw, fmt)
    if len(rom) < 0x1000:
        sys.exit(f"{path}: only {len(rom)} bytes; an N64 ROM is at least 0x1000 (header + IPL3)")

    (header_entry,) = struct.unpack(">I", rom[0x08:0x0C])
    crc1, crc2 = struct.unpack(">II", rom[0x10:0x18])
    cic = splat_rominfo.get_cic(rom)
    entry = splat_rominfo.get_entry_point(header_entry, cic)
    country = rom[0x3E]

    info = {
        "file": str(path),
        "format": fmt,
        "format_name": romfmt.FORMAT_NAMES[fmt],
        "size": len(rom),
        "sha1": hashlib.sha1(rom).hexdigest(),  # of the big-endian image
        "file_sha1": hashlib.sha1(raw).hexdigest(),
        "internal_name": rom[0x20:0x34].decode("ascii", "replace").rstrip(" \0"),
        "game_code": rom[0x3B:0x3F].decode("ascii", "replace"),
        "region": splat_rominfo.country_codes.get(country, f"unknown (0x{country:02X})"),
        "version": rom[0x3F],
        "libultra_version": chr(rom[0x0F]) if 0x20 <= rom[0x0F] < 0x7F else f"0x{rom[0x0F]:02X}",
        "header_entry_point": f"0x{header_entry:08X}",
        "entry_point": f"0x{entry:08X}",
        "cic": cic.ntsc_name,
        "cic_pal": cic.pal_name,
        "cic_known": cic is not splat_rominfo.unknown_cic,
        "ipl3_crc32": f"0x{zlib.crc32(rom[0x40:0x1000]):08X}",
        "header_crc1": f"0x{crc1:08X}",
        "header_crc2": f"0x{crc2:08X}",
        "warnings": warnings(rom, entry, cic),
    }
    return info


def warnings(rom: bytes, entry: int, cic) -> list[str]:
    """Signs that a game needs more than the toolkit's standard path."""
    out = []
    if cic is splat_rominfo.unknown_cic:
        out.append("unknown CIC (IPL3 CRC not in splat's table): entry point is the header's, unverified")
    if not 0x80000000 <= entry < 0x80800000:
        out.append(f"entry point 0x{entry:08X} is outside KSEG0 RDRAM: possible TLB-mapped code, which N64Recomp can't handle yet")
    for magic in COMPRESSION_MAGICS:
        n = rom.count(magic)
        if n:
            out.append(f"{n} '{magic.decode()}' header(s) found: possibly compressed code or overlays")
    try:
        ep = splat_rominfo.N64EntrypointInfo.parse_rom_bytes(rom, entry, size=0x100)
        if not ep.traditional_entrypoint:
            out.append("non-traditional entrypoint: splat's create_config analysis may be wrong")
    except Exception as e:  # analysis is only a hint; a synthetic or odd ROM can trip it
        out.append(f"splat could not analyse the entrypoint ({type(e).__name__}: {e})")
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("rom", type=Path)
    ap.add_argument("--json", action="store_true", help="print JSON")
    args = ap.parse_args()

    info = inspect(args.rom)
    if args.json:
        print(json.dumps(info, indent=2))
        return
    width = max(len(k) for k in info)
    for k, v in info.items():
        if k == "warnings":
            continue
        print(f"{k:<{width}}  {v}")
    for w in info["warnings"]:
        print(f"warning: {w}")


if __name__ == "__main__":
    main()
