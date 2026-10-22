"""Shared N64 ROM byte-order helpers for rominfo.py, romconvert.py and ucode_scan.py."""

import sys

# First four bytes of every commercial N64 ROM, in each dump format.
MAGIC = {
    bytes.fromhex("80371240"): "z64",  # big-endian (native)
    bytes.fromhex("37804012"): "v64",  # byte-swapped (16-bit)
    bytes.fromhex("40123780"): "n64",  # little-endian (32-bit)
}

FORMAT_NAMES = {
    "z64": "big-endian .z64",
    "v64": "byte-swapped .v64",
    "n64": "little-endian .n64",
}


def detect(data: bytes) -> str | None:
    """Byte order from the magic, or None if it isn't a recognised N64 ROM."""
    return MAGIC.get(bytes(data[:4]))


def to_z64(data: bytes, fmt: str) -> bytes:
    """Return the ROM in big-endian order."""
    if fmt == "z64":
        return bytes(data)
    if len(data) % 4:
        sys.exit(f"ROM size {len(data)} is not a multiple of 4; cannot fix byte order")
    out = bytearray(data)
    if fmt == "v64":
        out[0::2], out[1::2] = data[1::2], data[0::2]
    elif fmt == "n64":
        out[0::4], out[1::4], out[2::4], out[3::4] = data[3::4], data[2::4], data[1::4], data[0::4]
    else:
        raise ValueError(fmt)
    return bytes(out)


def ensure_toolkit_venv() -> None:
    """Re-run this script with the toolkit's venv Python if it isn't already.

    rominfo.py imports splat, which only lives in <toolkit>/.venv.
    """
    import os
    from pathlib import Path

    toolkit = Path(__file__).resolve().parent.parent
    venv = toolkit / ".venv"
    if Path(sys.prefix).resolve() == venv.resolve():
        return
    py = venv / "bin" / "python"
    if not py.exists():
        sys.exit(f"{venv} is missing; run {toolkit}/build.sh first")
    script = Path(sys.argv[0]).resolve()
    os.execv(py, [str(py), "-I", str(script), *sys.argv[1:]])
