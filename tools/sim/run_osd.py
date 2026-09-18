#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check what the cheat overlay actually draws.

tb_osd.sv runs a real cheat file through the real parser, the real title RAM
and the real renderer, and dumps the frame as a bitmap. This reads the glyphs
back out of that bitmap and compares the text against what the file says should
be on screen, so a wrong character, a shifted column or a title that never
arrived is a failure rather than something to notice by eye later.

    tools/sim/run_osd.py                 # every example file, both modes, every slot state
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

COLS, ROWS = 26, 18
CELL_W, CELL_H = 6, 8
SLOTS, PREFIX = 2, 6        # "1 ON  " ahead of a slot's name, as cheat_osd draws it
MASTER_LABEL = "CHEATS ENABLED"   # cheat_osd's MASTER_LABEL, the global switch's row


def compile_tb() -> None:
    os.makedirs(BUILD, exist_ok=True)
    subprocess.run(["iverilog", "-g2012", "-o", TB] +
                   [os.path.join(ROOT, s) for s in SOURCES], check=True)


def glyph_table() -> dict[tuple, str]:
    table = {}
    for i, rows in enumerate(genfont.glyphs()):
        table[tuple(rows)] = chr(genfont.FIRST + i)
    return table


def render(path: str, cart: bool, slots: int, master: bool) -> tuple[list[str], str]:
    out = subprocess.run([TB, f"+f={path}", f"+cart={int(cart)}",
                          f"+slots={slots}", f"+master={int(master)}"],
                         capture_output=True, text=True, check=True).stdout
    bitmap = [line[4:] for line in out.splitlines() if line.startswith("PIX ")]
    if len(bitmap) != ROWS * CELL_H:
        raise SystemExit(f"{path}: got {len(bitmap)} scanlines, want {ROWS * CELL_H}")
    return bitmap, out


def read_text(bitmap: list[str], table: dict[tuple, str]) -> list[str]:
    lines = []
    for r in range(ROWS):
        chars = []
        for c in range(COLS):
            # Six columns are read into the top of an eight bit row: the glyph
            # is five wide and the font byte is zero below it, so the key still
            # matches genfont exactly.
            cell = []
            for y in range(CELL_H):
                row = bitmap[r * CELL_H + y]
                bits = 0
                for x in range(CELL_W):
                    px = c * CELL_W + x
                    if px < len(row) and row[px] == "#":
                        bits |= 0x80 >> x
                cell.append(bits)
            key = tuple(cell)
            chars.append(table.get(key, "?" if any(cell) else " "))
        lines.append("".join(chars).rstrip())
    return lines


def expected(path: str, cart: bool, slots: int, master: bool) -> list[str]:
    groups = chtparse.parse(open(path, "rb").read())
    codes = sum(len(g.codes) for g in groups)
    # The renderer lays the header out in fixed columns rather than joining
    # words, so build it the same way instead of guessing at the spacing.
    cells = [" "] * COLS
    n, m = str(len(groups)), str(codes)
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

    def title(g, width):
        t = (g.desc or "").upper()[:width]
        return "".join(c if 32 <= ord(c) <= 95 else " " for c in t).rstrip()

    lines = [head, "CARTRIDGE" if cart else "ROM FILE"]
    lines.append(f"{MASTER_LABEL} {'ON' if master else 'OFF'}" if groups else "")
    for i, g in enumerate(groups[:SLOTS]):
        mark = "ON " if slots >> i & 1 else "OFF"
        lines.append(f"{i + 1} {mark} {title(g, COLS - PREFIX)}".rstrip())
    lines += [""] * (SLOTS - len(groups[:SLOTS]))
    rest_on = [g for g in groups[SLOTS:] if g.enabled]
    lines += [title(g, COLS) for g in rest_on[:ROWS - len(lines)]]
    while len(lines) < ROWS:
        lines.append("")
    return lines


def check(path: str, cart: bool, slots: int, master: bool, table: dict,
          show: bool) -> bool:
    bitmap, _ = render(path, cart, slots, master)
    got = read_text(bitmap, table)
    want = expected(path, cart, slots, master)
    name = os.path.basename(path)
    mode = "cartridge" if cart else "rom"
    print(f"--- {name}  ({mode}, slots {slots:02b}, master {'on' if master else 'off'})")
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
            for slots in range(4):
                for master in (False, True):
                    total += 1
                    ok += check(path, cart, slots, master, table, args.show)
    print(f"\n{ok}/{total} passed")
    return 0 if ok == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
