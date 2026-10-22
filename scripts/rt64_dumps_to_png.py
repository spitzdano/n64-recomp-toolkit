#!/usr/bin/env python3
"""rt64_dumps_to_png.py <dump dir> <out dir>: RT64 texture dumps -> PNG files named by their RT64 hash.

RT64 (developer "dump textures", or a runtime shell that sets State::dumpingTexturesDirectory) writes each
texture the game loads as <hash>.v<N>.tmem (all 4 KiB of TMEM) plus <hash>.v<N>.tile.json (tile descriptor,
width, height, TLUT). This decodes the texture exactly as RT64's shader samples it (TextureDecoder.hlsli
sampleTMEM: odd-row word swap, RGBA32 split across both TMEM halves, palettes in the upper half), so the PNG is
what the game showed. Writes <out>/<hash>.png and <out>/index.json (hash -> format, size, dims). The PNG names
are what an RT64 pack with "autoPath": "rt64" looks for.

No third-party modules: PNGs are written with zlib.
"""
import json
import struct
import sys
import zlib
from pathlib import Path

FMT = {0: "RGBA", 1: "YUV", 2: "CI", 3: "IA", 4: "I"}
SIZ = {0: 4, 1: 8, 2: 16, 3: 32}
TMEM_BYTES = 0x1000
PALETTE = 0x800


def png(path, w, h, rgba):
    raw = b"".join(b"\x00" + bytes(rgba[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.write_bytes(data)


def rgba16(v):
    r, g, b = (v >> 11) & 31, (v >> 6) & 31, (v >> 1) & 31
    return ((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2), 255 if v & 1 else 0)


def ia16(v):
    return (v >> 8, v >> 8, v >> 8, v & 0xFF)


def decode(tmem, tile, width, height, tlut):
    fmt, siz = tile["fmt"], tile["siz"]
    address, stride = tile["tmem"] << 3, tile["line"] << 3
    rgba32 = fmt == 0 and siz == 3
    uses_tlut = tlut in ("RGBA16", "IA16", 1, 2)
    tlut_kind = {"RGBA16": 1, "IA16": 2}.get(tlut, tlut)
    shift = 2 if rgba32 else siz
    mask = 0x7FF if (rgba32 or uses_tlut) else 0xFFF

    def load(rel, odd_row, or_addr=0):
        row_start = (rel // stride) * stride if stride else 0
        word = (rel - row_start) // 4
        final = address + row_start + ((word ^ 1) * 4) + (rel & 3) if odd_row else address + rel
        return tmem[((final & mask) | or_addr) & 0xFFF]

    out = bytearray(width * height * 4)
    for y in range(height):
        odd_row = y & 1
        for x in range(width):
            odd_col = x & 1
            pa = y * stride + ((x << shift) >> 1)
            v0, v1 = load(pa, odd_row), load(pa + 1, odd_row)
            v4 = (v0 >> (0 if odd_col else 4)) & 0xF
            if uses_tlut:
                pal = PALETTE + (tile["palette"] << 7) + (v4 << 3) if siz == 0 else PALETTE + (v0 << 3)
                pv = (tmem[(pal + 1) & 0xFFF]) | (tmem[pal & 0xFFF] << 8)
                c = rgba16(pv) if tlut_kind == 1 else ia16(pv)
            elif siz == 0:
                if fmt == 3:  # IA4
                    i = v4 & 0b1110
                    i = ((i << 4) | (i << 1) | (i >> 2)) & 0xFF
                    c = (i, i, i, 255 if v4 & 1 else 0)
                elif fmt == 2:  # CI4 without TLUT: index as intensity
                    i = (tile["palette"] << 4) | v4
                    c = (i, i, i, i)
                else:  # I4 (and RGBA4, which samples as I4)
                    i = (v4 << 4) | v4
                    c = (i, i, i, i)
            elif siz == 1:
                if fmt == 3:  # IA8
                    i, a = (v0 >> 4) * 17, (v0 & 0xF) * 17
                    c = (i, i, i, a)
                else:  # I8, and RGBA8/CI8 without TLUT
                    c = (v0, v0, v0, v0)
            elif siz == 2:
                v = (v0 << 8) | v1
                if fmt == 0:
                    c = rgba16(v)
                elif fmt == 3:
                    c = ia16(v)
                else:
                    c = (v0, v1, v0, v1)
            else:
                pa2 = pa if rgba32 else pa + 2
                orr = TMEM_BYTES >> 1 if rgba32 else 0
                v2, v3 = load(pa2, odd_row, orr), load(pa2 + 1, odd_row, orr)
                c = (v0, v1, v2, v3) if fmt == 0 else ((v0, v1, v0, v1) if odd_col else (v2, v3, v2, v3))
            out[(y * width + x) * 4:(y * width + x) * 4 + 4] = bytes(c)
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.splitlines()[0])
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    dst.mkdir(parents=True, exist_ok=True)
    index_path = dst / "index.json"
    index = json.loads(index_path.read_text()) if index_path.exists() else {}
    new = 0
    for info in sorted(src.glob("*.tile.json")):
        base = info.name[: -len(".tile.json")]           # <hash>.v<N>
        hash_, version = base.split(".v")
        if hash_ in index:
            continue
        j = json.loads(info.read_text())
        tmem = (src / f"{base}.tmem").read_bytes()
        if len(tmem) != TMEM_BYTES:
            print(f"skip {base}: tmem is {len(tmem)} bytes", file=sys.stderr)
            continue
        tile, w, h, tlut = j["tile"], j["width"], j["height"], j.get("tlut", "None")
        if not (0 < w <= 1024 and 0 < h <= 1024):
            continue
        png(dst / f"{hash_}.png", w, h, decode(tmem, tile, w, h, tlut))
        index[hash_] = {"fmt": FMT.get(tile["fmt"], tile["fmt"]), "siz": SIZ[tile["siz"]], "w": w, "h": h,
                        "tlut": tlut, "hash_version": int(version)}
        new += 1
    index_path.write_text(json.dumps(index, indent=1, sort_keys=True) + "\n")
    print(f"rt64_dumps_to_png.py: {new} new, {len(index)} total in {dst}")


if __name__ == "__main__":
    main()
