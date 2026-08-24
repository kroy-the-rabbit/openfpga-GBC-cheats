#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Convert a Quartus .rbf into the Analogue Pocket .rbf_r format.

The Pocket's APF loads the bitstream with the bit order within each byte
reversed relative to what Quartus emits. Byte order is unchanged.
"""
import sys

TABLE = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))


def main(src: str, dst: str) -> None:
    with open(src, "rb") as f:
        data = f.read()
    with open(dst, "wb") as f:
        f.write(data.translate(TABLE))
    print(f"{dst}: {len(data)} bytes")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} in.rbf out.rbf_r")
    main(sys.argv[1], sys.argv[2])
