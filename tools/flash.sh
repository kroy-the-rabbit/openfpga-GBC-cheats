#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Host-side: merge build/<target>/sd/ onto a mounted Pocket SD card, flush,
# verify the bitstream, and unmount so the card is safe to pull.
#   tools/flash.sh gbc [/run/media/$USER/pocket]
set -euo pipefail
TARGET=${1:?usage: flash.sh gbc|gb [mountpoint]}
SD=${2:-$(findmnt -rn -o TARGET | grep -E "^/run/media/$USER/" | head -1 || true)}
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/build/$TARGET/sd"

[[ -n "$SD" && -d "$SD" ]] || { echo "no SD card mounted (pass the mountpoint)" >&2; exit 1; }
[[ -d "$SD/Cores" && -d "$SD/Platforms" ]] || { echo "$SD does not look like a Pocket card (no Cores/ + Platforms/)" >&2; exit 1; }
[[ -d "$SRC" ]] || { echo "no build at $SRC, run make $TARGET first" >&2; exit 1; }
if [[ -f "$REPO/build/$TARGET/TIMING_FAILED" && -z "${FLASH_ANYWAY:-}" ]]; then
  echo "build/$TARGET missed timing; refusing to flash. Set FLASH_ANYWAY=1 to override." >&2
  exit 1
fi

CORE=$(ls "$SRC/Cores")
RBF=$(ls "$SRC/Cores/$CORE"/*.rbf_r | xargs -n1 basename)
echo "== flashing $CORE ($RBF) to $SD"
rsync -rt --no-perms --no-owner --no-group --exclude .gitkeep --itemize-changes "$SRC/" "$SD/" | grep -E '^>f' || true
sync
a=$(sha256sum "$SRC/Cores/$CORE/$RBF" | cut -c1-16); b=$(sha256sum "$SD/Cores/$CORE/$RBF" | cut -c1-16)
[[ "$a" == "$b" ]] || { echo "CHECKSUM MISMATCH $a != $b" >&2; exit 1; }
echo "== verified $RBF ($a)"
if [[ -n "${NO_UNMOUNT:-}" ]]; then
  echo "== left mounted (NO_UNMOUNT set); eject before removing the card"
else
  dev=$(findmnt -rn -o SOURCE "$SD")
  udisksctl unmount -b "$dev" >/dev/null && echo "== unmounted $dev, safe to remove"
fi
