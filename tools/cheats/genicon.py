#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Convert a PNG into the icon.bin the Pocket shows next to a core.

The format is not in Analogue's documentation, which links to an image format
page that 404s, so it was read back out of the icon this core inherited:

    36 x 36 pixels
    one 16-bit little endian word per pixel, of which only the low byte is used
    the value is an intensity, 0 is black
    column major: index = x * 36 + y, not the other way round
    2592 bytes, no header

Column major is the part that will waste an afternoon. Decoded row major the
image comes out transposed, which looks like a plausible icon rotated 90
degrees rather than like a mistake.

Colour is lost, so a flat logo needs help to survive: the alpha channel becomes
the silhouette and the luminance only modulates it, which keeps a light mark on
a dark body visible instead of turning the whole thing into one grey blob.

    tools/cheats/genicon.py <source.png> <dest.bin>...
    tools/cheats/genicon.py --show <icon.bin>      # print it as ASCII art

Needs Pillow, so run it from a venv:

    python3 -m venv .venv && .venv/bin/pip install pillow
"""
from __future__ import annotations

import struct
import sys

SIZE = 36
FLOOR, RANGE = 90, 165          # dimmest and brightest ink for a solid pixel


def encode(png: str) -> bytes:
    from PIL import Image                                  # noqa: PLC0415

    src = Image.open(png).convert("RGBA").resize((SIZE, SIZE), Image.LANCZOS)
    alpha, lum = src.getchannel("A").load(), src.convert("L").load()
    out = bytearray()
    for x in range(SIZE):                                  # column major
        for y in range(SIZE):
            v = int(alpha[x, y] / 255 * (FLOOR + RANGE * lum[x, y] / 255))
            out += struct.pack("<H", min(255, v))
    return bytes(out)


def show(path: str) -> None:
    data = open(path, "rb").read()
    if len(data) != SIZE * SIZE * 2:
        sys.exit(f"{path}: {len(data)} bytes, want {SIZE * SIZE * 2}")
    ramp = " .:-=+*#%@"
    grid = [[0] * SIZE for _ in range(SIZE)]
    for i in range(SIZE * SIZE):
        v = struct.unpack_from("<H", data, i * 2)[0] & 0xFF
        grid[i % SIZE][i // SIZE] = v
    for row in grid:
        print("".join(ramp[min(len(ramp) - 1, v * len(ramp) // 256)] for v in row))


def main(argv: list[str]) -> int:
    if not argv:
        sys.exit(__doc__.strip().splitlines()[0])
    if argv[0] == "--show":
        for p in argv[1:]:
            show(p)
        return 0
    src, dests = argv[0], argv[1:]
    if not dests:
        sys.exit("usage: genicon.py <source.png> <dest.bin>...")
    blob = encode(src)
    for d in dests:
        open(d, "wb").write(blob)
        print(f"wrote {d}: {len(blob)} bytes from {src}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
