#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Drive a .cht through the whole core path in simulation and check the result.

Sends the file as APF bridge writes at hardware rates, through data_loader's
dual clock FIFO, cheat_loader and CODES, then asserts that a CPU read of each
patched address comes back with the cheat value, and that a cheat whose slot
is off does nothing.

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


def expected(path: str, slots: int, master: bool):
    """(addr, value, compare, uses_compare, how) per address; how: 0 override, 1 poke, 2 neither."""
    groups = chtparse.parse(open(path, "rb").read())
    mask = (slots | (chtparse.enable_mask(groups) & ~3)) if master else 0

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

    live_addrs = {h[0] for h in hits}
    for gi, c in entries:
        if not (mask >> gi & 1) and c.address not in live_addrs:
            hits.append((c.address, c.value, c.compare or 0,
                         1 if c.compare is not None else 0, 2))

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


def run(path: str, slots: int = 3, master: bool = True) -> bool:
    hits, codes, groups, mask, n_entries = expected(path, slots, master)
    exp = os.path.join(BUILD, "expected.txt")
    with open(exp, "w") as f:
        for a, v, c, u, p in hits:
            f.write(f"{a} {v} {c} {u} {p}\n")

    out = subprocess.run([TB, f"+f={path}", f"+e={exp}",
                          f"+entries={n_entries}", f"+slots={slots}",
                          f"+master={int(master)}"],
                         capture_output=True, text=True).stdout
    ok = "PASS" in out and "OVERFLOW" not in out
    size = os.path.getsize(path)

    print(f"--- {os.path.basename(path)}  (slots {slots:02b}, master {'on' if master else 'off'})")
    poked = sum(1 for h in hits if h[4] == 1)
    off = sum(1 for h in hits if h[4] == 2)
    print(f"    file {size} bytes, model: {codes} codes, {groups} cheats, "
          f"{n_entries} entries, {len(hits)} checks "
          f"({poked} poked, {len(hits) - poked - off} read override, {off} off)")
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
    runs = [(p, 3, True) for p in files]
    if not sys.argv[1:]:
        fix = os.path.join(ROOT, "tools", "sim", "fixtures", "slots.cht")
        runs += [(fix, s, m) for m in (False, True) for s in range(4)]
    compile_tb()
    bad = [p for p, s, m in runs if not run(p, s, m)]
    if not bank_gate():
        bad.append("bank.cht")
    print()
    print(f"{len(runs) - len(bad)}/{len(runs)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
