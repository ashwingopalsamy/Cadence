#!/bin/bash
# S8: the app builds with Command Line Tools only.
set -eu
. "$(dirname "$0")/lib.sh"
spike_begin S8
ROOT=$(cd "$SPIKE_DIR/../.." && pwd)
CLT=/Library/Developer/CommandLineTools

dev=$(xcode-select -p 2>/dev/null || echo none)
case "$dev" in
  *CommandLineTools*) kind=CommandLineTools ;;
  none) kind=none ;;
  *) kind=Xcode ;;
esac
note "xcode-select -p: $dev ($kind)"

# Extra evidence: does a #Preview macro compile with this toolchain?
printf 'import SwiftUI\n#Preview { Text("x") }\n' >"$TMP/preview.swift"
if DEVELOPER_DIR="${DEVELOPER_DIR:-$([ -d "$CLT" ] && echo "$CLT" || xcode-select -p 2>/dev/null)}" \
   xcrun swiftc -typecheck -parse-as-library "$TMP/preview.swift" 2>"$TMP/preview.log"; then
  note "#Preview macro: compiles"
else
  note "#Preview macro: fails ($(grep -m1 'error:' "$TMP/preview.log" | cut -c1-140)); keep previews out of the CLT build"
fi

if ! grep -q 'CadenceApp' "$ROOT/Package.swift" || [ ! -d "$ROOT/Sources/CadenceApp" ]; then
  result S8 FAIL "product CadenceApp does not exist yet in $ROOT"; exit 0
fi
if [ ! -d "$CLT" ]; then
  result S8 MANUAL "Command Line Tools are not installed at $CLT; run xcode-select --install and rerun"; exit 0
fi

# Force the CLT toolchain even if full Xcode is the active developer dir.
cd "$ROOT"
if DEVELOPER_DIR="$CLT" swift build -c release --product CadenceApp >"$TMP/build.log" 2>&1; then
  result S8 PASS "swift build -c release --product CadenceApp succeeded with DEVELOPER_DIR=$CLT (active dev dir: $kind)"
else
  result S8 FAIL "build failed with Command Line Tools: $(grep -m1 'error:' "$TMP/build.log" | cut -c1-200)"
fi
