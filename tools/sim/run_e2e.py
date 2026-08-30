#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Drive a .cht through the whole core path in simulation and check the result.

Sends the file as APF bridge writes at hardware rates, through data_loader's
dual clock FIFO, cheat_loader and CODES, then asserts that a CPU read of each
patched address comes back with the cheat value.

    tools/sim/run_e2e.py                      # the files in examples/
    tools/sim/run_e2e.py path/to/game.cht
"""
from __future__ import annotations

import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "cheats"))
import chtparse  # noqa: E402

BUILD = os.path.join(ROOT, "build", "sim")
TB = os.path.join(BUILD, "tb_e2e")

SOURCES = ["tools/sim/tb_e2e.sv", "tools/sim/dcfifo.sv",
           "src/gb/data_loader.sv", "src/gb/cheat_loader.sv",
           "src/gb/cheatcodes.sv", "src/gb/cheat_poker.sv"]


def compile_tb() -> None:
    os.makedirs(BUILD, exist_ok=True)
    subprocess.run(["iverilog", "-g2012", "-o", TB]
                   + [os.path.join(ROOT, s) for s in SOURCES], check=True)


def expected(path: str):
    """What the core should do per address, after enable flags and overwrites.

    Each entry is (addr, value, compare, uses_compare, poked). `poked` means
    cheat_poker writes it into RAM and the read override must stay quiet;
    everything else is a read override as before.
    """
    groups = chtparse.parse(open(path, "rb").read())
    mask = chtparse.enable_mask(groups)

    # The code store holds one entry per (address, cheat), enabled or not: a
    # later code replaces an earlier one only when both belong to the same
    # cheat. Different cheats aiming at one address coexist.
    table: dict[tuple[int, int], object] = {}
    codes = 0
    for g in groups:
        for c in g.codes:
            if codes >= chtparse.MAX_CODES:
                break
            codes += 1
            table[(c.address, g.index)] = (g.index, c)

    entries = list(table.values())
    n_entries = len(entries)
    live = [(gi, c) for gi, c in entries if mask >> gi & 1]

    # A poked address ends up holding whatever the last entry wrote, because
    # the poker walks the table in order and each write lands.
    poked_last: dict[int, object] = {}
    hits: list[tuple[int, int, int, int, int]] = []
    for _gi, c in live:
        if chtparse.applied_by(c) == "poke":
            poked_last[c.address] = c
        else:
            hits.append((c.address, c.value, c.compare or 0,
                         1 if c.compare is not None else 0, 0))
    for a, c in poked_last.items():
        hits.append((a, c.value, 0, 0, 1))

    hits.sort()
    return hits, codes, len(groups), mask, n_entries


def bank_gate() -> bool:
    """A GameShark code that names a work RAM bank writes only in that bank.

    The type byte is not decoration: without the check a code aimed at
    $D000-$DFFF lands in whichever bank SVBK happens to select at vblank, which
    is a different variable somewhere else in the game.
    """
    fix = os.path.join(ROOT, "tools", "sim", "fixtures", "bank.cht")
    exp = os.path.join(BUILD, "expected.txt")
    open(exp, "w").close()                      # no per-address assertions here

    want = {1: {0xD0A0: 0x11, 0xD0A1: 0x22},    # any-bank plus the bank-1 code
            2: {0xD0A0: 0x11, 0xD0A2: 0x33}}    # any-bank plus the bank-2 code
    ok = True
    print("--- bank.cht (GameShark type byte)")
    for bank, expect in want.items():
        out = subprocess.run([TB, f"+f={fix}", f"+e={exp}", f"+bank={bank}"],
                             capture_output=True, text=True).stdout
        got = {int(a, 16): int(v, 16)
               for a, v in re.findall(r"WROTE ([0-9a-f]{4})=([0-9a-f]{2})", out)}
        good = got == expect
        ok &= good
        print(f"    SVBK={bank}: wrote {{{', '.join(f'{a:04X}={v:02X}' for a, v in sorted(got.items()))}}}"
              f"  {'ok' if good else 'FAIL, expected ' + str({hex(a): hex(v) for a, v in expect.items()})}")
    return ok


def run(path: str) -> bool:
    hits, codes, groups, mask, n_entries = expected(path)
    exp = os.path.join(BUILD, "expected.txt")
    with open(exp, "w") as f:
        for a, v, c, u, p in hits:
            f.write(f"{a} {v} {c} {u} {p}\n")

    out = subprocess.run([TB, f"+f={path}", f"+e={exp}",
                          f"+entries={n_entries}"],
                         capture_output=True, text=True).stdout
    ok = "PASS" in out and "OVERFLOW" not in out
    size = os.path.getsize(path)

    print(f"--- {os.path.basename(path)}")
    poked = sum(h[4] for h in hits)
    print(f"    file {size} bytes, model: {codes} codes, {groups} cheats, "
          f"mask {mask:08x}, {n_entries} entries, {len(hits)} checks "
          f"({poked} poked, {len(hits) - poked} read override)")
    for line in out.strip().splitlines():
        if line.startswith(("RESULT", "FAIL", "DCFIFO", "CHECKED", "FAILURES")):
            print(f"    {line}")
    print(f"    {'PASS' if ok else 'FAIL'}")
    return ok


def main() -> int:
    files = sys.argv[1:] or (
        sorted(glob.glob(os.path.join(ROOT, "examples", "*.cht")))
        # the awkward cases live here: duplicate addresses, bank-qualified codes
        + [os.path.join(ROOT, "tools", "sim", "fixtures", "dupaddr.cht")])
    if not files:
        print("no .cht files given")
        return 2
    compile_tb()
    bad = [p for p in files if not run(p)]
    if not bank_gate():
        bad.append("bank.cht")
    print()
    print(f"{len(files) - len(bad)}/{len(files)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
