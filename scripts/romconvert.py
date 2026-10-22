#!/usr/bin/env python3
"""romconvert.py <in> <out.z64>: convert a .v64 or .n64 dump to big-endian .z64.

Refuses to overwrite its input, and refuses to overwrite any existing output.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import romfmt  # noqa: E402


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip())
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    if dst.exists() and dst.resolve() == src.resolve():
        sys.exit("romconvert.py: output is the input; refusing to overwrite it")
    if dst.exists():
        sys.exit(f"romconvert.py: {dst} already exists; refusing to overwrite it")
    data = src.read_bytes()
    fmt = romfmt.detect(data)
    if fmt is None:
        sys.exit(f"romconvert.py: {src} is not an N64 ROM (first bytes {data[:4].hex()})")
    out = romfmt.to_z64(data, fmt)
    with open(dst, "xb") as f:  # "x": never clobber, even if it appeared just now
        f.write(out)
    note = " (already big-endian; copied as is)" if fmt == "z64" else ""
    print(f"romconvert.py: {romfmt.FORMAT_NAMES[fmt]} -> big-endian .z64: {dst}{note}")


if __name__ == "__main__":
    main()
