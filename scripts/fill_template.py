#!/usr/bin/env python3
"""fill_template.py <template-dir> <dest-dir> <values.json>: copy a template, filling placeholders.

values.json maps placeholder names (e.g. "__TAG__") to strings. Placeholders are
replaced in file contents and in file and folder names; a file called
"gitignore" becomes ".gitignore". Fails if any __PLACEHOLDER__ is left over.
"""

import json
import re
import shutil
import sys
from pathlib import Path

LEFTOVER = re.compile(r"__[A-Z][A-Z0-9_]*__")


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit(__doc__.splitlines()[0])
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    values = json.loads(Path(sys.argv[3]).read_text())

    def fill(s: str) -> str:
        for k, v in values.items():
            s = s.replace(k, str(v))
        return s

    left = []
    for p in sorted(src.rglob("*")):
        rel = Path(fill(str(p.relative_to(src))))
        if rel.name == "gitignore":
            rel = rel.with_name(".gitignore")
        out = dst / rel
        if p.is_dir():
            out.mkdir(parents=True, exist_ok=True)
            continue
        out.parent.mkdir(parents=True, exist_ok=True)
        text = fill(p.read_text())
        out.write_text(text)
        shutil.copymode(p, out)
        if LEFTOVER.search(text) or LEFTOVER.search(str(rel)):
            left.append(f"{rel}: {sorted(set(LEFTOVER.findall(text + str(rel))))}")
    if left:
        sys.exit("fill_template.py: unfilled placeholders:\n  " + "\n  ".join(left))


if __name__ == "__main__":
    main()
