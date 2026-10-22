#!/usr/bin/env python3
"""splat_relocate.py <yaml> <tag>: point a create_config yaml at the game-project layout.

new-game.sh moves create_config's yaml to split/<tag>.yaml; this rewrites its
options so splat runs from there with the project root as base_path:

    target_path  baserom.z64             asm_path    split/asm
    elf_path     build/<tag>.elf         asset_path  split/bin
    ld_script    split/<tag>.ld          src_path    split/src
    symbols      split/symbol_addrs.txt  build_path  build
    relocs       split/reloc_addrs.txt   macros      split/include
    undefined    split/undefined_{funcs,syms}_auto.txt
    o_as_suffix  False (objects are foo.s.o / foo.bin.o, so the source is unambiguous)

Only the options block is touched; segments are left exactly as create_config wrote them.
"""

import re
import sys
from pathlib import Path

SCALARS = {
    "base_path": "..",
    "target_path": "baserom.z64",
    "elf_path": "build/{tag}.elf",
    "ld_script_path": "split/{tag}.ld",
    "asm_path": "split/asm",
    "asset_path": "split/bin",
    "src_path": "split/src",
    "build_path": "build",
    "cache_path": "split/.splache",
    "generated_asm_macros_directory": "split/include",
    "undefined_funcs_auto_path": "split/undefined_funcs_auto.txt",
    "undefined_syms_auto_path": "split/undefined_syms_auto.txt",
    "o_as_suffix": "False",
}
LISTS = {
    "symbol_addrs_path": "split/symbol_addrs.txt",
    "reloc_addrs_path": "split/reloc_addrs.txt",
}


def relocate(text: str, tag: str) -> str:
    head, sep, segments = text.partition("\nsegments:")
    if not sep:
        sys.exit("splat_relocate.py: no 'segments:' block found")
    lines = head.split("\n")
    out, done, skip_list_items = [], set(), False
    for line in lines:
        if skip_list_items:
            if re.match(r"^\s+-\s", line):
                continue
            skip_list_items = False
        m = re.match(r"^(\s*)#?\s*([a-z_0-9]+):(.*)$", line)
        key = m.group(2) if m else None
        if m and m.group(1) == "  " or (m and line.startswith("  #")):
            if key in SCALARS:
                out.append(f"  {key}: {SCALARS[key].format(tag=tag)}")
                done.add(key)
                continue
            if key in LISTS:
                out.append(f"  {key}:")
                out.append(f"    - {LISTS[key]}")
                done.add(key)
                skip_list_items = True
                continue
        out.append(line)
    missing = [k for k in (*SCALARS, *LISTS) if k not in done]
    if missing:
        # Append anything create_config didn't mention, at the end of options.
        while out and out[-1] == "":
            out.pop()
        out.append("")
        out.append("  # Added by new-game.sh (project layout)")
        for k in missing:
            if k in SCALARS:
                out.append(f"  {k}: {SCALARS[k].format(tag=tag)}")
            else:
                out.append(f"  {k}:")
                out.append(f"    - {LISTS[k]}")
        out.append("")
    return "\n".join(out) + sep + segments


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__.splitlines()[0])
    path, tag = Path(sys.argv[1]), sys.argv[2]
    path.write_text(relocate(path.read_text(), tag))


if __name__ == "__main__":
    main()
