#!/usr/bin/env bash
# The app carries exactly the entitlements in App/Cadence.entitlements, the helper has none, the bundle
# holds only those two binaries, and neither contains networking (docs/SPEC.md sections 8.3, 14.3, 14.6).
# Usage: tools/check_entitlements.sh PATH_TO_APP
set -euo pipefail

app="${1:?usage: tools/check_entitlements.sh PATH_TO_APP}"
main="$app/Contents/MacOS/Cadence"
helper="$app/Contents/Helpers/cadence"
here="$(cd "$(dirname "$0")" && pwd)"
info="$app/Contents/Info.plist"
fail=0

entitlements() { codesign -d --entitlements - --xml "$1" 2>/dev/null || true; }
# Captured first: grep -q closes the pipe early, which pipefail would report as a failure.
has_runtime() { local details; details="$(codesign -d --verbose=2 "$1" 2>&1)"; grep -q 'flags=.*runtime' <<<"$details"; }

codesign --verify --deep --strict "$app" || { echo "entitlements: the signature does not verify"; fail=1; }

# Exact equality: a deny-list would pass an sbpl exception or a broader file exception.
app_xml="$(entitlements "$main")"
if ! python3 -I -c 'import plistlib,sys; a=plistlib.loads(sys.stdin.buffer.read()); b=plistlib.load(open(sys.argv[1],"rb")); sys.exit(a!=b)' \
  "$here/../App/Cadence.entitlements" <<<"$app_xml" 2>/dev/null; then
  echo "entitlements: the app does not carry exactly App/Cadence.entitlements"; fail=1
fi
grep -q 'com.apple.security.network' <<<"$app_xml" && { echo "entitlements: the app has a network key"; fail=1; }
if [ -n "$(entitlements "$helper")" ]; then
  echo "entitlements: the helper must have no entitlements"; fail=1
fi

while IFS= read -r -d '' file; do
  [ "$file" = "$main" ] || [ "$file" = "$helper" ] && continue
  kind="$(file -b "$file")"
  case "$kind" in *Mach-O*) echo "entitlements: unexpected binary ${file#"$app"/}"; fail=1 ;; esac
done < <(find "$app/Contents" -type f -print0)

for bin in "$main" "$helper"; do
  has_runtime "$bin" || { echo "entitlements: no hardened runtime on $(basename "$bin")"; fail=1; }
  "$here/check_symbols.sh" "$bin" || fail=1
done

# The built plists: accessory app, agent file named for the bundle id, every placeholder filled.
if [ "$(plutil -extract LSUIElement raw "$info" 2>/dev/null)" != "true" ]; then
  echo "entitlements: Info.plist does not set LSUIElement"; fail=1
fi
id="$(plutil -extract CFBundleIdentifier raw "$info" 2>/dev/null || true)"
agent="$app/Contents/Library/LaunchAgents/$id.agent.plist"
if ! plutil -lint "$agent" >/dev/null 2>&1; then
  echo "entitlements: no valid agent plist for $id"; fail=1
elif grep -q '@[A-Z_]*@' "$agent" "$info"; then
  echo "entitlements: a plist still has a placeholder"; fail=1
fi

[ $fail -eq 0 ] && echo "entitlements: exact entitlements, helper clean, no networking in either binary"
exit $fail
