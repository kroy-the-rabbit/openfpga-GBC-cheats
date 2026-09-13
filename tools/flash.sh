#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Host-side: merge a core zip onto a mounted Pocket SD card, flush, and verify
# every file written. The card stays mounted unless UNMOUNT=1.
#   tools/flash.sh build/gbc/kroy.GBC_<version>.zip [/run/media/$USER/pocket]
set -euo pipefail
ZIP=${1:?usage: flash.sh <core zip> [mountpoint]}
SD=${2:-$(findmnt -rn -o TARGET | grep -E "^/run/media/$USER/" | head -1 || true)}
REPO=$(cd "$(dirname "$0")/.." && pwd)

[[ -f "$ZIP" ]] || { echo "no zip at $ZIP" >&2; exit 1; }
[[ -n "$SD" && -d "$SD" ]] || { echo "no SD card mounted (pass the mountpoint)" >&2; exit 1; }
[[ -d "$SD/Cores" && -d "$SD/Platforms" ]] || { echo "$SD does not look like a Pocket card (no Cores/ + Platforms/)" >&2; exit 1; }

# The timing gate is the report fetched beside the zip. Worst slack is read
# from its sta.summary section, which is the build's own, not a stale local one.
REPORT="$(dirname "$ZIP")/report.txt"
if [[ -f "$REPORT" ]]; then
  worst=$(sed -n '/^---- sta.summary/,$p' "$REPORT" \
          | awk '/^Slack/ {if (!s || $3 + 0 < m) {s = 1; m = $3 + 0}} END {printf "%.3f", m}')
  if awk -v v="$worst" 'BEGIN {exit !(v < 0)}' && [[ -z "${FLASH_ANYWAY:-}" ]]; then
    echo "$REPORT: worst slack $worst ns; refusing to flash. Set FLASH_ANYWAY=1 to override." >&2
    exit 1
  fi
  echo "== timing: worst slack $worst ns"
else
  echo "== no report.txt beside $ZIP; timing not checked"
fi

mkdir -p "$REPO/build"
TMP=$(mktemp -d "$REPO/build/flash.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
unzip -q "$ZIP" -d "$TMP"

CORE=$(ls "$TMP/Cores")
echo "== flashing $CORE from $(basename "$ZIP") to $SD"
rsync -rt --no-perms --no-owner --no-group --itemize-changes "$TMP/" "$SD/" | grep -E '^>f' || true
sync

bad=0
while IFS= read -r -d '' f; do
  rel=${f#"$TMP/"}
  cmp -s "$f" "$SD/$rel" || { echo "MISMATCH $rel" >&2; bad=1; }
done < <(find "$TMP" -type f -print0)
[[ $bad -eq 0 ]] || exit 1
RBF=$(ls "$TMP/Cores/$CORE"/*.rbf_r)
echo "== verified $(find "$TMP" -type f | wc -l) files, $(basename "$RBF") $(sha256sum "$RBF" | cut -c1-16)"

if [[ -n "${UNMOUNT:-}" ]]; then
  dev=$(findmnt -rn -o SOURCE "$SD")
  udisksctl unmount -b "$dev" >/dev/null && echo "== unmounted $dev, safe to remove"
else
  echo "== left mounted; eject before removing the card"
fi
