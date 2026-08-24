#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Download the Quartus Prime Lite installer + Cyclone V device pack into tools/podman/dl/.
# Lite edition needs no login or license. Files are verified by byte size
# (Altera does not publish checksums on the CDN); re-run to resume/verify.
set -euo pipefail

QVER=${QVER:-25.1std.0}
QBUILD=${QBUILD:-1129}
BASE="https://downloads.intel.com/akdlm/software/acdsinst/${QVER%.*}/${QBUILD}/ib_installers"
DL="$(cd "$(dirname "$0")" && pwd)/dl"
mkdir -p "$DL"

# name                                         expected size (bytes)
FILES=(
  "QuartusLiteSetup-${QVER}.${QBUILD}-linux.run 1982715698"
  "cyclonev-${QVER}.${QBUILD}.qdz               1443834466"
)

for entry in "${FILES[@]}"; do
  read -r name size <<<"$entry"
  dst="$DL/$name"
  if [[ -f "$dst" && "$(stat -c %s "$dst")" == "$size" ]]; then
    echo "ok       $name"
    continue
  fi
  echo "fetching $name ($((size / 1048576)) MiB)"
  curl -fL --retry 5 --retry-delay 5 -C - -o "$dst" "$BASE/$name"
  actual=$(stat -c %s "$dst")
  if [[ "$actual" != "$size" ]]; then
    echo "size mismatch for $name: got $actual, expected $size" >&2
    exit 1
  fi
done
chmod +x "$DL/QuartusLiteSetup-${QVER}.${QBUILD}-linux.run"
echo "installers ready in $DL"
