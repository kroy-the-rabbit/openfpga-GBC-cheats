#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Summarize a finished build: utilization, STA summary, worst slack per analysis
# type. Needs only awk/sed, so it runs on the host or in the container.
#   tools/podman/report.sh gbc|gb   -> build/<target>/report.txt
set -euo pipefail

TARGET=${1:?usage: report.sh gbc|gb}
REPO=${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}
BDIR="$REPO/build/$TARGET"
OUT="$BDIR/src/output_files"
test -f "$OUT/ap_core.fit.summary" || { echo "no fitter output in $OUT" >&2; exit 1; }

worst() {  # worst slack for one analysis type across all corners
  awk -v want="$1" '
    /^Type/ { t = $0 }
    /^Slack/ {
      split(t, a, " Model ");            # a[2] = "<Type> '"'"'<clock>'"'"'"
      n = index(a[2], " '"'"'");
      typ = substr(a[2], 1, n - 1);
      if (typ == want && (!seen || $3 + 0 < min)) { seen = 1; min = $3 + 0; line = t }
    }
    END { if (seen) printf "%-22s %8.3f ns   %s\n", want, min, substr(line, 9); else printf "%-22s   (none)\n", want }
  ' "$OUT/ap_core.sta.summary"
}

{
  echo "target:    $TARGET"
  echo "commit:    ${GIT_SHA:-unknown}${GIT_DIRTY:+ (dirty)}"
  echo "quartus:   $(cat "$BDIR/quartus.version" 2>/dev/null || echo unknown)"
  echo "elapsed:   $(cat "$BDIR/elapsed" 2>/dev/null || echo '?') s"
  echo
  echo "---- worst slack per analysis type (all corners) ----"
  for t in Setup Hold Recovery Removal "Minimum Pulse Width"; do worst "$t"; done
  echo
  echo "---- utilization ----"
  grep -E "Logic utilization|Total registers|Total block memory bits|Total PLLs|Total DSP|Total pins" "$OUT/ap_core.fit.summary"
  echo
  echo "---- fit.summary ----"
  cat "$OUT/ap_core.fit.summary"
  echo
  echo "---- sta.summary ----"
  cat "$OUT/ap_core.sta.summary"
} > "$BDIR/report.txt"

sed -n '1,/^---- utilization/{/^---- utilization/d;p}' "$BDIR/report.txt"
grep -E "Logic utilization|Total registers|Total block memory bits|Total PLLs" "$OUT/ap_core.fit.summary"
echo "full report: $BDIR/report.txt"

# Quartus exits 0 on a design that misses timing, so gate on it here. A
# bitstream with negative slack may work on the bench and fail elsewhere.
rm -f "$BDIR/TIMING_FAILED"
worst=$(awk '/^Slack/ {if (!seen || $3 + 0 < m) {seen = 1; m = $3 + 0}} END {printf "%.3f", m}' \
        "$OUT/ap_core.sta.summary")
if awk -v v="$worst" 'BEGIN {exit !(v < 0)}'; then
  echo
  echo "TIMING FAILED: worst slack ${worst} ns. Not fit to flash."
  echo "  see $BDIR/report.txt, and tools/podman/report.sh for the failing corner"
  touch "$BDIR/TIMING_FAILED"
  exit 3
fi
echo "timing met: worst slack ${worst} ns"
