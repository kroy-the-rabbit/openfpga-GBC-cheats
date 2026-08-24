#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs INSIDE the container. Builds one target (gbc|gb) from a copy of src/,
# produces the Pocket bitstream, an SD-card tree, a zip, and a resource/timing
# report under build/<target>/. The checked-in src/ tree is never modified.
set -euo pipefail

TARGET=${1:?usage: build-core.sh gbc|gb}
REPO=${REPO:-/work}
BDIR="$REPO/build/$TARGET"
SRC="$BDIR/src"
HERE="$(cd "$(dirname "$0")" && pwd)"

case "$TARGET" in
  gbc) ISGBC=1 ;;
  gb)  ISGBC=0 ;;
  *)   echo "unknown target: $TARGET (want gbc or gb)" >&2; exit 2 ;;
esac

CORE_DIR=$(ls -d "$REPO/pkg/$TARGET/Cores"/*/ | head -1)
CORE_NAME=$(basename "$CORE_DIR")
VERSION=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['core']['metadata']['version'])" "$CORE_DIR/core.json")
RBF_NAME=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['core']['cores'][0]['filename'])" "$CORE_DIR/core.json")

echo "== target=$TARGET core=$CORE_NAME version=$VERSION bitstream=$RBF_NAME"

# 1. Sync source into the build dir. Excluded dirs are Quartus scratch and
#    survive across runs so incremental compiles still work; `make clean` wipes them.
mkdir -p "$SRC"
rsync -a --delete \
  --exclude output_files/ --exclude db/ --exclude incremental_db/ \
  "$REPO/src/" "$SRC/"

# 2. Patch the build copy for the target.
sed -i -E "s/^\`define isgbc [01]\$/\`define isgbc $ISGBC/" "$SRC/core/core_top.sv"
grep -q "^\`define isgbc $ISGBC\$" "$SRC/core/core_top.sv" || { echo "failed to set isgbc" >&2; exit 1; }
# Timing closure settings. Upstream builds with FITTER_EFFORT "FAST FIT", which
# trades placement quality for compile time: slack then swings by more than a
# nanosecond between runs of the same design, and the marginal hold path inside
# the RTC FIFO's dcfifo (clk_74a to clk_74a, +0.048 ns even on the untouched
# baseline) tipped negative on one GB build. STANDARD FIT costs compile time and
# gives repeatable closure; OPTIMIZE_HOLD_TIMING is set explicitly so the fitter
# always fixes internal hold violations rather than only IO ones.
# These are build-environment choices, applied to the build copy only, so the
# checked-in project file stays as upstream has it.
sed -i 's/FITTER_EFFORT "FAST FIT"/FITTER_EFFORT "STANDARD FIT"/' "$SRC/ap_core.qsf"
grep -q OPTIMIZE_HOLD_TIMING "$SRC/ap_core.qsf" || \
  printf '\nset_global_assignment -name OPTIMIZE_HOLD_TIMING "ALL PATHS"\n' >> "$SRC/ap_core.qsf"

# Optional fitter seed. The design has a marginal hold path inside the PLL's
# own output counter (+0.048 ns even on the untouched upstream baseline), and
# placement variance can tip it a picosecond negative. Re-running with another
# seed is the right answer there, not a design change.
if [[ -n "${SEED:-}" ]]; then
  printf '\nset_global_assignment -name SEED %s\n' "$SEED" >> "$SRC/ap_core.qsf"
  echo "== fitter seed $SEED"
fi

# Use every core. Upstream qsf already sets this; keep it set if that ever changes.
# (printf with a leading newline: the qsf has no trailing newline.)
grep -q NUM_PARALLEL_PROCESSORS "$SRC/ap_core.qsf" || \
  printf '\nset_global_assignment -name NUM_PARALLEL_PROCESSORS ALL\n' >> "$SRC/ap_core.qsf"

# 3. Compile. SKIP_COMPILE=1 repackages existing outputs (e.g. after editing
#    only pkg/ JSON) without touching Quartus.
cd "$SRC"
if [[ -z "${SKIP_COMPILE:-}" ]]; then
  start=$(date +%s)
  quartus_sh --flow compile ap_core 2>&1 | tee "$BDIR/build.log"
  end=$(date +%s)
  echo "$((end - start))" > "$BDIR/elapsed"
  quartus_sh --version | sed -n 2p > "$BDIR/quartus.version"
else
  echo "== SKIP_COMPILE set, packaging existing outputs"
fi
test -f output_files/ap_core.rbf || { echo "no .rbf produced, see $BDIR/build.log" >&2; exit 1; }

# 4. Bitstream + SD tree + zip. The packaged core.json gets an identifying
#    SemVer prerelease version (<base>-cheats.<sha>[.dirty]) and today's date
#    so the Pocket's core menu says exactly which commit is loaded. pkg/ in
#    the repo keeps the upstream base version.
python3 "$HERE/reverse_bits.py" output_files/ap_core.rbf "$BDIR/$RBF_NAME"
rm -rf "$BDIR/sd"
rsync -a --exclude .gitkeep "$REPO/pkg/$TARGET/" "$BDIR/sd/"
cp "$BDIR/$RBF_NAME" "$BDIR/sd/Cores/$CORE_NAME/$RBF_NAME"
# A tagged build is named after its tag, so the Pocket menu reads a version a
# human can compare at a glance: 1.4.0-cheats.2 is obviously not .1. Untagged
# builds keep the commit sha, which is what you want while iterating.
STAMP="${RELEASE_NAME:-}"
STAMP="${STAMP#v}"
[[ -n "$STAMP" ]] || STAMP="${VERSION}-cheats.${GIT_SHA:-nogit}${GIT_DIRTY:+.dirty}"
python3 - "$BDIR/sd/Cores/$CORE_NAME/core.json" "$STAMP" "$(date -u +%Y-%m-%d)" <<'PY'
import json, sys
path, version, date = sys.argv[1:]
assert len(version) <= 31, f"version too long for APF: {version}"
j = json.load(open(path))
j["core"]["metadata"]["version"] = version
j["core"]["metadata"]["date_release"] = date
json.dump(j, open(path, "w"), indent=2)
open(path, "a").write("\n")
print(f"stamped core.json: version={version} date_release={date}")
PY
ZIP="$BDIR/${CORE_NAME}_${STAMP}.zip"
rm -f "$ZIP"
(cd "$BDIR/sd" && zip -qr "$ZIP" .)

# 5. Report.
echo
echo "== done: $TARGET"
echo "   bitstream: $BDIR/$RBF_NAME"
echo "   sd tree:   $BDIR/sd/"
echo "   zip:       $ZIP"
echo
"$HERE/report.sh" "$TARGET"
