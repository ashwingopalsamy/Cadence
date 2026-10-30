#!/bin/bash
# Runs spike checks S1..S9 and prints a block to paste into docs/SPIKES.md. Always exits 0.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
export BUNDLE_PREFIX=${BUNDLE_PREFIX:-in.ashwingopalsamy.cadence.spike}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT TERM

for n in 1 2 3 4 5 6 7 8 9; do
  echo "== S$n =="
  bash "$DIR/s$n.sh" 2>&1 | tee "$T/s$n.out" || true
done

DATE=$(date +%F)
MACOS=$(sw_vers -productVersion 2>/dev/null || echo n/a)
SWIFT=$( (swift --version 2>/dev/null || true) | head -1)
[ -n "$SWIFT" ] || SWIFT=n/a

echo
echo "### Paste into docs/SPIKES.md"
echo
echo "| Spike | Result | Evidence | Date | macOS | Swift |"
echo "|---|---|---|---|---|---|"
for n in 1 2 3 4 5 6 7 8 9; do
  line=$( (grep -h "^S$n " "$T/s$n.out" 2>/dev/null || true) | head -1)
  if [ -z "$line" ]; then line="S$n FAIL check exited without a result line"; fi
  status=$(printf '%s' "$line" | cut -d' ' -f2)
  evidence=$(printf '%s' "$line" | cut -d' ' -f3- | tr '|' '/')
  echo "| S$n | $status | $evidence | $DATE | $MACOS | $SWIFT |"
done
echo
echo "MANUAL rows: follow the numbered steps above, then replace MANUAL with PASS or FAIL."
exit 0
