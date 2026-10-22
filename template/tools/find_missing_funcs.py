"""find_missing_funcs.py: code addresses stored in data (vtables, callback tables) that are not function starts in the ELF.

N64Recomp turns `jalr` into a runtime lookup by address, so a function nobody calls directly and splat never
found has no entry and the game aborts with "Failed to find function at 0x...". This scans the main code segment
(the first `code` segment in split/__TAG__.yaml, up to the next segment) for words that point into it, and reports
those that are not a known function start but sit right after a `jr $ra` + delay slot (very likely real function
starts). Jump-table entries (runs of pointers into one function) are left out.

Run from the project root after tools/build_elf.sh:
    find_missing_funcs.py [--exclude 0xROMSTART-0xROMEND ...]
--exclude skips ROM ranges whose words are not function pointers (the raw exception handler, for one).
Output lines are splat symbol_addrs.txt lines, size filled in up to the next known start: review them, add them to
split/symbol_addrs.txt, then split and build again.
"""
import bisect
import re
import struct
import subprocess
import sys

import yaml

TAG = "__TAG__"


def code_segment():
    """(rom start, vram, rom end) of the first code segment in the splat yaml."""
    cfg = yaml.safe_load(open(f"split/{TAG}.yaml"))
    segs = cfg["segments"]
    for i, seg in enumerate(segs):
        if isinstance(seg, dict) and seg.get("type") == "code":
            nxt = segs[i + 1] if i + 1 < len(segs) else None
            end = nxt["start"] if isinstance(nxt, dict) else nxt[0]
            return seg["start"], seg["vram"], end
    sys.exit(f"find_missing_funcs.py: no code segment in split/{TAG}.yaml")


exclude = []
args = sys.argv[1:]
while args:
    if args[0] == "--exclude" and len(args) > 1 and re.fullmatch(r"0x[0-9a-fA-F]+-0x[0-9a-fA-F]+", args[1]):
        a, b = args[1].split("-")
        exclude.append((int(a, 16), int(b, 16)))
        args = args[2:]
    else:
        sys.exit(__doc__)

CODE_ROM, CODE_VRAM, CODE_END_ROM = code_segment()
CODE_END_VRAM = CODE_VRAM + (CODE_END_ROM - CODE_ROM)
rom = open("baserom.z64", "rb").read()
word = lambda o: struct.unpack(">I", rom[o:o + 4])[0]
to_rom = lambda a: a - CODE_VRAM + CODE_ROM

starts = {}
for line in subprocess.check_output(["mips-linux-gnu-nm", "-n", f"build/{TAG}.elf"], text=True).splitlines():
    p = line.split()
    # Not local labels, nor splat's/the linker script's segment bounds (code_TEXT_START, main_VRAM, ...).
    if len(p) == 3 and p[1] in "tTWwAa" and not p[2].startswith((".L", "_binary")) \
            and not p[2].endswith(("_START", "_END", "_VRAM")):
        a = int(p[0], 16)
        if CODE_VRAM <= a < CODE_END_VRAM:
            starts[a] = p[2]
sorted_starts = sorted(starts)


def is_code_ptr(w):
    return CODE_VRAM <= w < CODE_END_VRAM and w % 4 == 0


def containing(a):
    i = bisect.bisect_right(sorted_starts, a) - 1
    return sorted_starts[i] if i >= 0 else None


def next_start(a):
    i = bisect.bisect_right(sorted_starts, a)
    return sorted_starts[i] if i < len(sorted_starts) else CODE_END_VRAM


def in_jump_table(a, off):
    """True if the pointer at ROM `off` is in a run of code pointers (zeros allowed) with other entries inside the
    same function as `a`: a switch's jump table. Vtables point at different functions."""
    run = [off]
    for step in (-4, 4):
        o = off + step
        while CODE_ROM <= o < CODE_END_ROM and (is_code_ptr(word(o)) or word(o) == 0):
            if word(o):
                run.append(o)
            o += step
    ca = containing(a)
    return any(word(o) != a and containing(word(o)) == ca for o in run)


found = {}
for off in range(CODE_ROM, CODE_END_ROM, 4):
    w = word(off)
    if is_code_ptr(w) and w not in starts:
        found.setdefault(w, []).append(off)

cands = []
for a, refs in sorted(found.items()):
    o = to_rom(a)
    if any(lo <= o < hi for lo, hi in exclude) or o < CODE_ROM + 12:
        continue
    after_ret = word(o - 8) == 0x03E00008 or (word(o - 4) == 0 and word(o - 12) == 0x03E00008)  # jr $ra; delay slot
    if not after_ret or all(in_jump_table(a, r) for r in refs):
        continue
    cands.append((a, refs))
cand_addrs = [a for a, _ in cands]
for a, refs in cands:
    i = bisect.bisect_right(cand_addrs, a)
    end = min(next_start(a), cand_addrs[i] if i < len(cand_addrs) else CODE_END_VRAM)
    print(f"func_{a:08X} = 0x{a:08X}; // type:func size:0x{end - a:X}  (from {len(refs)} data word(s), first at ROM 0x{refs[0]:X})")
print(f"find_missing_funcs.py: {len(cands)} found", file=sys.stderr)
