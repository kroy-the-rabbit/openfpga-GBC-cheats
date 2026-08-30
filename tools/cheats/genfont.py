#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate src/gb/cheat_font.sv: the font the cheat overlay draws with.

64 glyphs, ASCII 32..95: space, punctuation, digits and uppercase. Lowercase
is folded to uppercase when a title is stored, because descenders need more
than 8 rows and the Game Boy screen is 160 pixels wide, which is 20 characters.

The glyphs are drawn here by hand as 5x7 art rather than rendered from a TTF.
A 9 point face reduced to an 8 pixel box loses the crossbar of an A and closes
up the counter of a 0: legible type at this size is drawn, not scaled. Each
glyph is placed in an 8x8 cell, 5 columns of ink and 3 of gap, so text needs no
extra spacing.

The output is a plain SystemVerilog array rather than a $readmemh, so synthesis
and simulation see the same data with no file lookup and no extra qsf entry.
The generated file is committed; this only needs rerunning if a glyph changes.

    tools/cheats/genfont.py            # write src/gb/cheat_font.sv
    tools/cheats/genfont.py --show     # print the glyphs as ASCII art
    tools/cheats/genfont.py --check    # fail if the committed file is stale
"""
from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "src", "gb", "cheat_font.sv")

FIRST, LAST = 32, 95

# 5 wide, 7 tall, in ASCII order from 32. '#' is ink.
GLYPHS = """
.....|..#..|.#.#.|.#.#.|..#..|##..#|.##..|..#..
.....|..#..|.#.#.|#####|.####|##..#|#..#.|..#..
.....|..#..|.....|.#.#.|#.#..|...#.|.##..|.....
.....|..#..|.....|#####|.###.|..#..|##.#.|.....
.....|.....|.....|.#.#.|..#.#|.#...|#..#.|.....
.....|.....|.....|#####|####.|#..##|#..#.|.....
.....|..#..|.....|.#.#.|..#..|#..##|.##.#|.....
"""

MORE = """
..#..|..#..|.....|.....|.....|.....|.....|....#
.#...|...#.|#.#.#|..#..|.....|.....|.....|...#.
#....|....#|.###.|..#..|.....|#####|.....|..#..
#....|....#|#####|#####|.....|.....|.....|..#..
#....|....#|.###.|..#..|.....|.....|.....|.#...
.#...|...#.|#.#.#|..#..|..#..|.....|..#..|#....
..#..|..#..|.....|.....|.#...|.....|.....|#....
"""

DIGITS = """
.###.|..#..|.###.|.###.|...#.|#####|..##.|#####
#...#|.##..|#...#|#...#|..##.|#....|.#...|....#
#..##|..#..|....#|....#|.#.#.|#....|#....|...#.
#.#.#|..#..|..##.|..##.|#..#.|####.|####.|..#..
##..#|..#..|.#...|....#|#####|....#|#...#|.#...
#...#|..#..|#....|#...#|...#.|#...#|#...#|.#...
.###.|.###.|#####|.###.|...#.|.###.|.###.|.#...
"""

MORE2 = """
.###.|.###.|.....|.....|...#.|.....|.#...|.###.
#...#|#...#|.....|.....|..#..|.....|..#..|#...#
#...#|#...#|..#..|..#..|.#...|#####|...#.|....#
.###.|.####|.....|.....|#....|.....|....#|..##.
#...#|....#|.....|.....|.#...|#####|...#.|..#..
#...#|#...#|..#..|..#..|..#..|.....|..#..|.....
.###.|.###.|.....|.#...|...#.|.....|.#...|..#..
"""

ALPHA = """
.###.|.###.|####.|.###.|####.|#####|#####|.###.
#...#|#...#|#...#|#...#|#..#.|#....|#....|#...#
#...#|#...#|#...#|#....|#...#|#....|#....|#....
#.###|#####|####.|#....|#...#|####.|####.|#..##
#.###|#...#|#...#|#....|#...#|#....|#....|#...#
#....|#...#|#...#|#...#|#..#.|#....|#....|#...#
.###.|#...#|####.|.###.|####.|#####|#....|.####
"""

ALPHA2 = """
#...#|.###.|....#|#...#|#....|#...#|#...#|.###.
#...#|..#..|....#|#..#.|#....|##.##|##..#|#...#
#...#|..#..|....#|#.#..|#....|#.#.#|##..#|#...#
#####|..#..|....#|##...|#....|#...#|#.#.#|#...#
#...#|..#..|....#|#.#..|#....|#...#|#..##|#...#
#...#|..#..|#...#|#..#.|#....|#...#|#..##|#...#
#...#|.###.|.###.|#...#|#####|#...#|#...#|.###.
"""

ALPHA3 = """
####.|.###.|####.|.###.|#####|#...#|#...#|#...#
#...#|#...#|#...#|#...#|..#..|#...#|#...#|#...#
#...#|#...#|#...#|#....|..#..|#...#|#...#|#...#
####.|#...#|####.|.###.|..#..|#...#|#...#|#.#.#
#....|#.#.#|#.#..|....#|..#..|#...#|#...#|##.##
#....|#..#.|#..#.|#...#|..#..|#...#|.#.#.|##.##
#....|.##.#|#...#|.###.|..#..|.###.|..#..|#...#
"""

ALPHA4 = """
#...#|#...#|#####|.###.|#....|.###.|..#..|.....
#...#|#...#|....#|.#...|.#...|...#.|.#.#.|.....
.#.#.|.#.#.|...#.|.#...|..#..|...#.|#...#|.....
..#..|..#..|..#..|.#...|...#.|...#.|.....|.....
.#.#.|..#..|.#...|.#...|....#|...#.|.....|.....
#...#|..#..|#....|.#...|.....|...#.|.....|.....
#...#|..#..|#####|.###.|.....|.###.|.....|#####
"""

BLOCKS = (GLYPHS, MORE, DIGITS, MORE2, ALPHA, ALPHA2, ALPHA3, ALPHA4)


def glyphs() -> list[list[int]]:
    out: list[list[int]] = []
    for block in BLOCKS:
        rows = [line for line in block.strip("\n").split("\n") if line]
        if len(rows) != 7:
            sys.exit(f"a block has {len(rows)} rows, want 7")
        cells = [r.split("|") for r in rows]
        n = len(cells[0])
        for i in range(n):
            bits = []
            for r in range(7):
                art = cells[r][i]
                if len(art) != 5:
                    sys.exit(f"glyph {len(out)} row {r} is {len(art)} wide, want 5")
                v = 0
                for x, c in enumerate(art):
                    if c == "#":
                        v |= 0x80 >> x
                bits.append(v)
            bits.append(0)                       # row 7: gap under the glyph
            out.append(bits)
    if len(out) != LAST - FIRST + 1:
        sys.exit(f"{len(out)} glyphs, want {LAST - FIRST + 1}")
    return out


def as_art(gs: list[list[int]]) -> str:
    lines = []
    for i, rows in enumerate(gs):
        lines.append(f"--- {chr(FIRST + i)!r} ({FIRST + i})")
        for b in rows:
            lines.append("    " + "".join("#" if b & (0x80 >> x) else "."
                                          for x in range(8)))
    return "\n".join(lines)


def as_verilog(gs: list[list[int]]) -> str:
    lines = [
        "// SPDX-License-Identifier: GPL-3.0-or-later",
        "// Generated by tools/cheats/genfont.py. Do not edit by hand.",
        "//",
        "// 8x8 cells holding 5x7 glyphs for ASCII 32..95, drawn by cheat_osd.sv",
        "// over the game picture. One byte per row, MSB is the leftmost pixel.",
        "",
        "module cheat_font (",
        "\tinput  wire [5:0] ch,        // character code minus 32",
        "\tinput  wire [2:0] row,",
        "\toutput wire [7:0] bits",
        ");",
        "",
        "\tlogic [7:0] rom [0:511];",
        "\tassign bits = rom[{ch, row}];",
        "",
        "\tinitial begin",
    ]
    for i, rows in enumerate(gs):
        c = chr(FIRST + i)
        label = "space" if c == " " else c
        lines.append(f"\t\t// {label}")
        for j, b in enumerate(rows):
            lines.append(f"\t\trom[{i * 8 + j:3d}] = 8'h{b:02X};")
    lines += ["\tend", "", "endmodule", ""]
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    gs = glyphs()
    if "--show" in argv:
        print(as_art(gs))
        return 0
    text = as_verilog(gs)
    if "--check" in argv:
        have = open(OUT).read() if os.path.exists(OUT) else ""
        if have == text:
            print(f"font: in step, {len(gs)} glyphs")
            return 0
        print("font: src/gb/cheat_font.sv is stale, rerun tools/cheats/genfont.py",
              file=sys.stderr)
        return 1
    open(OUT, "w").write(text)
    print(f"wrote {OUT}: {len(gs)} glyphs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
