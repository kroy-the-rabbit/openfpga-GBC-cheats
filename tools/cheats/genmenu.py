#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the cheat entries in both packages' interact.json.

A global switch, two cheat slots under it (the first two cheats in the file,
each with a check box that overrides the file's `enable` key), and a switch
for the overlay that names them. Every later cheat follows its `enable` key.

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

# ids are persistence keys; these never persist, but stay stable anyway
ID_MASTER, ID_SHOW, ID_SLOT1, ID_SLOT2 = 1010, 1011, 1012, 1013

# One address per switch: masked bits of a shared word failed on hardware.
ADDR_MASTER = "0xF3000000"
ADDR_SLOT1 = "0xF300000C"
ADDR_SLOT2 = "0xF3000014"
ADDR_SHOW = "0xF3000010"

TARGETS = (("gbc", "kroy.GBC"), ("gb", "kroy.GB"))


def switch(name: str, id_: int, address: str) -> dict:
    # off at every launch, never remembered
    return {
        "name": name, "id": id_, "type": "check",
        "enabled": True, "persist": False, "address": address,
        "mask": "0xFFFFFFFE", "defaultval": "0x00000000", "value": "0x00000001",
    }


def cheat_entries() -> list[dict]:
    return [
        switch("Cheat slot 1", ID_SLOT1, ADDR_SLOT1),
        switch("Cheat slot 2", ID_SLOT2, ADDR_SLOT2),
        switch("Cheats enabled", ID_MASTER, ADDR_MASTER),
        switch("Show cheats", ID_SHOW, ADDR_SHOW),
    ]


def is_cheat_entry(x: dict) -> bool:
    return 1010 <= x.get("id", 0) <= 1030


def build() -> dict[str, str]:
    files: dict[str, str] = {}
    for tgt, core in TARGETS:
        path = f"pkg/{tgt}/Cores/{core}/interact.json"
        j = json.load(open(os.path.join(ROOT, path)),
                      object_pairs_hook=collections.OrderedDict)
        v = j["interact"]["variables"]
        base = [x for x in v if not is_cheat_entry(x)]
        cheats = [collections.OrderedDict(e) for e in cheat_entries()]
        # Keep the cheat controls together with the Load Cheats slot, which APF
        # draws at the top of the menu. Appended at the end they sat below
        # seven unrelated options, a screen away from the file they act on.
        # Reset core stays first, being where every other core puts it.
        head = base[:1] if base and base[0].get("type") == "action" else []
        v[:] = head + cheats + base[len(head):]
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
    print("menu: two cheat slots, global switch, on screen list")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
