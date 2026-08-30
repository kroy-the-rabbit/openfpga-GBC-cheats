#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Cross-check src/gb/cheat_loader.sv against tools/cheats/chtparse.py.

Runs the RTL in Icarus Verilog over real libretro .cht files and diffs the
codes it emits against the Python reference model, code for code.

    tools/sim/run.py                 # every .cht under $CHT_DB
    tools/sim/run.py -n 200          # a sample
    tools/sim/run.py path/to/x.cht   # specific files
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import os
import random
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "cheats"))
import chtparse  # noqa: E402

# A corpus of real .cht files to check against. This repo does not carry one:
# point CHT_DB at a checkout of the libretro database, or at any directory of
# .cht files. Without one the cross-check is skipped and the rest of the suite
# still runs.
DB = os.environ.get("CHT_DB") or os.path.join(ROOT, "external",
                                              "libretro-database", "cht")
BUILD = os.path.join(ROOT, "build", "sim")
TB = os.path.join(BUILD, "tb_cheat_loader")

LINE = re.compile(
    r"CODE grp=(\d+) usecmp=(\d+) addr=([0-9a-f]+) cmp=([0-9a-f]+) val=([0-9a-f]+)")
TOTAL = re.compile(r"TOTAL codes=(\d+) groups=(\d+) mask=([0-9a-f]+)")


def compile_tb() -> None:
    os.makedirs(BUILD, exist_ok=True)
    subprocess.run(
        ["iverilog", "-g2012", "-o", TB,
         os.path.join(ROOT, "tools", "sim", "tb_cheat_loader.sv"),
         os.path.join(ROOT, "src", "gb", "cheat_loader.sv")],
        check=True)


def rtl(path: str) -> tuple[list[tuple], tuple[int, int, int]]:
    out = subprocess.run([TB, f"+f={path}"], capture_output=True, text=True,
                         check=True).stdout
    codes = [(int(g), int(u), int(a, 16), int(c, 16), int(v, 16))
             for g, u, a, c, v in LINE.findall(out)]
    m = TOTAL.search(out)
    return codes, ((int(m.group(1)), int(m.group(2)), int(m.group(3), 16))
                   if m else (-1, -1, -1))


def model(path: str) -> tuple[list[tuple], tuple[int, int, int]]:
    groups = chtparse.parse(open(path, "rb").read())
    codes = [(g.index, 1 if c.compare is not None else 0, c.address,
              c.compare or 0, c.value)
             for g in groups for c in g.codes]
    return codes, (len(codes), len(groups), chtparse.enable_mask(groups))


def check(path: str) -> tuple[str, str | None]:
    try:
        rc, rt = rtl(path)
        mc, mt = model(path)
    except Exception as e:                      # noqa: BLE001
        return path, f"error: {e}"
    if rc != mc:
        for i, (a, b) in enumerate(zip(rc, mc)):
            if a != b:
                return path, f"code {i} differs: rtl={a} model={b}"
        return path, f"length differs: rtl={len(rc)} model={len(mc)}"
    if rt != mt:
        return path, (f"totals differ (codes, groups, enable mask): "
                      f"rtl={rt} model={mt}")
    return path, None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("-n", type=int, default=0, help="sample N files at random")
    ap.add_argument("-j", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args()

    files = args.files or [os.path.join(d, f)
                           for d, _, fs in os.walk(DB) for f in fs
                           if f.endswith(".cht")]
    if not files:
        print(f"SKIPPED: no .cht files under {DB}\n"
              f"  set CHT_DB to a directory of .cht files to run the "
              f"cross-check (see docs/CHEATS.md)", file=sys.stderr)
        return 0
    files.sort()
    if args.n and args.n < len(files):
        files = random.Random(0).sample(files, args.n)

    compile_tb()
    bad = 0
    with cf.ThreadPoolExecutor(max_workers=args.j) as ex:
        for i, (path, err) in enumerate(ex.map(check, files), 1):
            if err:
                bad += 1
                print(f"FAIL {os.path.basename(path)}: {err}")
            if i % 200 == 0:
                print(f"  {i}/{len(files)} checked, {bad} failures", flush=True)
    print(f"\n{len(files) - bad}/{len(files)} files match the reference model")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
