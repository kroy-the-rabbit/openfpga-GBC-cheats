#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the cheat entries in both packages' interact.json.

Which cheats are on is decided by the cheat file itself, through the `enable`
key that libretro .cht files already carry, so the menu needs only two entries:
a global switch and a readout showing what was parsed.

    tools/cheats/genmenu.py            # rewrite the JSON
    tools/cheats/genmenu.py --check    # verify it is up to date
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

MAX_ENTRIES = 16     # APF's ceiling on interact.json entries
MAX_GROUPS = 32      # cheat groups the RTL can hold (matches cheat_loader)

# id block reserved for cheats; ids are persistence keys, so they must be stable
ID_MASTER, ID_SHOW = 1010, 1011

ADDR_MASTER = "0xF3000000"   # bit 0 global cheat switch, bit 1 show the list

TARGETS = (("gbc", "budude2.GBC"), ("gb", "budude2.GB"))


def cheat_entries() -> list[dict]:
    return [{
        # Deliberately not persisted. APF keys saved values by widget id, so a
        # value written by one build can be restored into a control that has
        # since changed meaning, and this switch decides whether the core
        # writes to the game's RAM. It starts on every launch and the file
        # next to the ROM decides the rest, which is a state you can reason
        # about; a remembered one is not.
        "name": "Cheats enabled", "id": ID_MASTER, "type": "check",
        "enabled": True, "persist": False, "address": ADDR_MASTER,
        "mask": "0xFFFFFFFE", "defaultval": "0x00000001", "value": "0x00000001",
    }, {
        # Draws the names of the enabled cheats over the game picture. That is
        # the only place a core can put text: APF fixes every menu label in
        # this file at build time, so a menu row can never say more than
        # "Cheat 1". Not persisted either, and off by default, because it
        # covers the game.
        "name": "Show cheats", "id": ID_SHOW, "type": "check",
        "enabled": True, "persist": False, "address": ADDR_MASTER,
        "mask": "0xFFFFFFFD", "defaultval": "0x00000000", "value": "0x00000002",
    }]


def is_cheat_entry(x: dict) -> bool:
    return x.get("id", 0) in (ID_MASTER, ID_SHOW) or \
        1011 <= x.get("id", 0) <= 1030      # older per-cheat toggles and page


def build() -> dict[str, str]:
    files: dict[str, str] = {}
    for tgt, core in TARGETS:
        path = f"pkg/{tgt}/Cores/{core}/interact.json"
        j = json.load(open(os.path.join(ROOT, path)),
                      object_pairs_hook=collections.OrderedDict)
        v = j["interact"]["variables"]
        base = [x for x in v if not is_cheat_entry(x)]
        v[:] = base + [collections.OrderedDict(e) for e in cheat_entries()]
        assert len(v) <= MAX_ENTRIES, f"{path}: {len(v)} entries"
        files[path] = json.dumps(j, indent=2) + "\n"
    return files


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="fail if the generated files are out of date")
    args = ap.parse_args()

    files = build()
    stale = []
    for rel, text in files.items():
        path = os.path.join(ROOT, rel)
        current = open(path).read() if os.path.exists(path) else None
        if current == text:
            continue
        if args.check:
            stale.append(rel)
        else:
            open(path, "w").write(text)
            print(f"wrote {rel}")
    if stale:
        print("out of date, run tools/cheats/genmenu.py:", *stale, sep="\n  ")
        return 1
    print("menu: global switch + on screen list; "
          "per-cheat state comes from the .cht")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
