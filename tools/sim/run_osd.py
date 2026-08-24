#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check what the cheat overlay actually draws.

tb_osd.sv runs a real cheat file through the real parser, the real title RAM
and the real renderer, and dumps the frame as a bitmap. This reads the glyphs
back out of that bitmap and compares the text against what the file says should
be on screen, so a wrong character, a shifted column or a title that never
arrived is a failure rather than something to notice by eye later.

    tools/sim/run_osd.py                 # every example file, both modes
    tools/sim/run_osd.py --show          # print the screen as text
"""
from __future__ import annotations

import argparse
import glob
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "cheats"))
import chtparse                                              # noqa: E402
import genfont                                               # noqa: E402

BUILD = os.path.join(ROOT, "build", "sim")
TB = os.path.join(BUILD, "tb_osd")
SOURCES = ["tools/sim/tb_osd.sv", "src/gb/cheat_loader.sv",
           "src/gb/cheat_titles.sv", "src/gb/cheat_font.sv",
           "src/gb/cheat_osd.sv"]

COLS, ROWS, CELL = 20, 18, 8
TITLE_W = 20


def compile_tb() -> None:
    os.makedirs(BUILD, exist_ok=True)
    subprocess.run(["iverilog", "-g2012", "-o", TB] +
                   [os.path.join(ROOT, s) for s in SOURCES], check=True)


def glyph_table() -> dict[tuple, str]:
    table = {}
    for i, rows in enumerate(genfont.glyphs()):
        table[tuple(rows)] = chr(genfont.FIRST + i)
    return table


def render(path: str, cart: bool) -> tuple[list[str], str]:
    out = subprocess.run([TB, f"+f={path}", f"+cart={int(cart)}"],
                         capture_output=True, text=True, check=True).stdout
    bitmap = [line[4:] for line in out.splitlines() if line.startswith("PIX ")]
    if len(bitmap) != ROWS * CELL:
        raise SystemExit(f"{path}: got {len(bitmap)} scanlines, want {ROWS * CELL}")
    return bitmap, out


def read_text(bitmap: list[str], table: dict[tuple, str]) -> list[str]:
    lines = []
    for r in range(ROWS):
        chars = []
        for c in range(COLS):
            cell = []
            for y in range(CELL):
                row = bitmap[r * CELL + y]
                bits = 0
                for x in range(CELL):
                    px = c * CELL + x
                    if px < len(row) and row[px] == "#":
                        bits |= 0x80 >> x
                cell.append(bits)
            key = tuple(cell)
            chars.append(table.get(key, "?" if any(cell) else " "))
        lines.append("".join(chars).rstrip())
    return lines


def expected(path: str, cart: bool) -> list[str]:
    groups = chtparse.parse(open(path, "rb").read())
    on = [g for g in groups if g.enabled]
    codes = sum(len(g.codes) for g in on)
    head = f"{len(on)} CHEATS {codes} CODES"
    # The renderer lays the header out in fixed columns rather than joining
    # words, so build it the same way instead of guessing at the spacing.
    cells = [" "] * COLS
    n, m = str(len(on)), str(codes)
    if len(n) == 2:
        cells[0], cells[1] = n[0], n[1]
    else:
        cells[1] = n
    for i, ch in enumerate("CHEATS"):
        cells[3 + i] = ch
    if len(m) == 2:
        cells[10], cells[11] = m[0], m[1]
    else:
        cells[11] = m
    for i, ch in enumerate("CODES"):
        cells[13 + i] = ch
    head = "".join(cells).rstrip()
    if not groups:
        head = "NO CHEATS LOADED"

    lines = [head, "CARTRIDGE" if cart else "ROM FILE"]
    for g in on[:ROWS - 2]:
        title = (g.desc or "").upper()[:TITLE_W]
        title = "".join(c if 32 <= ord(c) <= 95 else " " for c in title)
        lines.append(title.rstrip())
    while len(lines) < ROWS:
        lines.append("")
    return lines


def check(path: str, cart: bool, table: dict, show: bool) -> bool:
    bitmap, _ = render(path, cart)
    got = read_text(bitmap, table)
    want = expected(path, cart)
    name = os.path.basename(path)
    mode = "cartridge" if cart else "rom"
    print(f"--- {name}  ({mode})")
    if show:
        for line in got:
            print(f"    |{line}")
    bad = 0
    for i, (g, w) in enumerate(zip(got, want)):
        if g != w:
            bad += 1
            print(f"    row {i}: got {g!r}")
            print(f"           want {w!r}")
    print("    PASS" if not bad else f"    FAIL: {bad} rows differ")
    return bad == 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--show", action="store_true", help="print the screen")
    args = ap.parse_args()

    files = args.files or sorted(glob.glob(os.path.join(ROOT, "examples", "*.cht")))
    if not files:
        print("no example cheat files", file=sys.stderr)
        return 2

    compile_tb()
    table = glyph_table()
    ok = 0
    total = 0
    for path in files:
        for cart in (False, True):
            total += 1
            ok += check(path, cart, table, args.show)
    print(f"\n{ok}/{total} passed")
    return 0 if ok == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
