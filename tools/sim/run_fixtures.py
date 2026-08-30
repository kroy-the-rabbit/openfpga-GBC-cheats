#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Adversarial parser cases, checked against expected output rather than a model.

tools/sim/run.py compares the RTL against tools/cheats/chtparse.py over the
whole libretro database, which proves the two agree and nothing more. A flaw
present in both is invisible to it, and one was: the parser armed on the bare
characters `_code`, so a comment reading `# _code means "Facade"` emitted a
phantom Game Genie patch, and both sides did it, and 2456 files still matched.

These cases carry the answer with them, so agreement cannot hide a mistake.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUILD = os.path.join(ROOT, "build", "sim")
TB = os.path.join(BUILD, "tb_fixtures")
FIX = os.path.join(ROOT, "tools", "sim", "fixtures")

LINE = re.compile(
    r"CODE grp=(\d+) usecmp=(\d+) addr=([0-9a-f]+) cmp=([0-9a-f]+) val=([0-9a-f]+)")

# path -> [(group, addr, value)], exactly what the core must end up holding
CASES = {
    # a comment mentioning the key, then a description that is valid hex
    "freetext.cht":      [(0, 0xC6AA, 0x40)],
    # keys whose names merely contain _code / _desc as substrings
    "substring_key.cht": [(0, 0xC6AA, 0x0C)],
    # descriptions made entirely of words that parse as Game Genie codes
    "hexy_desc.cht":     [(0, 0xC6B0, 0x32), (1, 0xC6A5, 0x99)],
    # two codes whose delimiters are adjacent, no gap for the emit handshake
    "backtoback.cht":    None,      # covered by its own testbench, shape only
}


def compile_tb() -> None:
    os.makedirs(BUILD, exist_ok=True)
    subprocess.run(
        ["iverilog", "-g2012", "-o", TB,
         os.path.join(ROOT, "tools", "sim", "tb_cheat_loader.sv"),
         os.path.join(ROOT, "src", "gb", "cheat_loader.sv")], check=True)


def run(path: str) -> list[tuple[int, int, int]]:
    out = subprocess.run([TB, f"+f={path}"], capture_output=True, text=True,
                         check=True).stdout
    return [(int(g), int(a, 16), int(v, 16))
            for g, _u, a, _c, v in LINE.findall(out)]


def main() -> int:
    compile_tb()
    bad = 0
    for name, want in CASES.items():
        if want is None:
            continue
        got = run(os.path.join(FIX, name))
        ok = got == want
        bad += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name}")
        if not ok:
            print(f"       expected {[(g, hex(a), hex(v)) for g, a, v in want]}")
            print(f"       got      {[(g, hex(a), hex(v)) for g, a, v in got]}")
    n = sum(1 for v in CASES.values() if v is not None)
    print(f"\n{n - bad}/{n} adversarial cases behave as specified")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
