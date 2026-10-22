#!/usr/bin/env python3
"""make_synthetic_rom.py <outdir>: write a synthetic 1 MiB "ROM" in all three byte orders.

Nothing here comes from a real game: a hand-written header, a zero IPL3, a
traditional libultra-style entrypoint routine at 0x1000, a tiny main()
function, and one fake graphics-microcode version string. It exists so the
toolkit's scripts can be tested without a ROM.
"""

import struct
import sys
from pathlib import Path

SIZE = 0x100000
ENTRY = 0x80000400
UCODE_OFFSET = 0x20000
UCODE_TEXT = b"RSP Gfx ucode F3DEX       fifo 2.08  Synthetic Test String 2026."


def build() -> bytes:
    rom = bytearray(SIZE)
    struct.pack_into(">4sIII", rom, 0x00, bytes.fromhex("80371240"), 0x0F, ENTRY, 0x0000144C)
    struct.pack_into(">II", rom, 0x10, 0x12345678, 0x9ABCDEF0)
    rom[0x20:0x34] = b"SYNTHETIC TEST ROM  "
    rom[0x3B:0x3F] = b"NSYE"  # N = cartridge, SY = game, E = North America
    rom[0x3F] = 0  # version
    # Entrypoint at 0x80000400 (ROM 0x1000), shaped like libultra's:
    # clear BSS, set the stack, jump to main.
    code = [
        0x3C088000,  # lui   t0, 0x8000        (bss start hi)
        0x25080800,  # addiu t0, t0, 0x0800
        0x3C090000,  # lui   t1, 0x0000        (bss size hi)
        0x25290100,  # addiu t1, t1, 0x0100
        0x2129FFF8,  # addi  t1, t1, -8        loop:
        0xAD000000,  # sw    zero, 0(t0)
        0xAD000004,  # sw    zero, 4(t0)
        0x1520FFFC,  # bnez  t1, loop
        0x21080008,  # addi  t0, t0, 8         (delay slot)
        0x3C0A8000,  # lui   t2, 0x8000        (main hi)
        0x3C1D8001,  # lui   sp, 0x8001        (stack top hi)
        0x254A0460,  # addiu t2, t2, 0x0460    (main = 0x80000460)
        0x01400008,  # jr    t2
        0x27BD0000,  # addiu sp, sp, 0x0000    (delay slot)
        0x00000000,  # nop
        0x00000000,  # nop
    ]
    main = [
        0x27BDFFE8,  # addiu sp, sp, -0x18
        0xAFBF0014,  # sw    ra, 0x14(sp)
        0x8FBF0014,  # lw    ra, 0x14(sp)
        0x03E00008,  # jr    ra
        0x27BD0018,  # addiu sp, sp, 0x18      (delay slot)
        0x00000000,
        0x00000000,
        0x00000000,
    ]
    words = code + [0] * ((0x60 - len(code) * 4) // 4) + main
    for i, w in enumerate(words):
        struct.pack_into(">I", rom, 0x1000 + i * 4, w)
    rom[UCODE_OFFSET:UCODE_OFFSET + len(UCODE_TEXT)] = UCODE_TEXT
    return bytes(rom)


def swap16(b: bytes) -> bytes:
    out = bytearray(b)
    out[0::2], out[1::2] = b[1::2], b[0::2]
    return bytes(out)


def swap32(b: bytes) -> bytes:
    out = bytearray(b)
    out[0::4], out[1::4], out[2::4], out[3::4] = b[3::4], b[2::4], b[1::4], b[0::4]
    return bytes(out)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__.splitlines()[0])
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    rom = build()
    (out / "synthetic.z64").write_bytes(rom)
    (out / "synthetic.v64").write_bytes(swap16(rom))
    (out / "synthetic.n64").write_bytes(swap32(rom))
    print(f"wrote synthetic.z64/.v64/.n64 to {out} (ucode string at 0x{UCODE_OFFSET:X})")


if __name__ == "__main__":
    main()
