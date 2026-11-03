#!/usr/bin/env bash
# Proves tools/check_entitlements.sh passes the built app and fails each bad bundle for the right reason.
# Usage: tools/tests/check_entitlements_test.sh PATH_TO_APP
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="${1:?usage: tools/tests/check_entitlements_test.sh PATH_TO_APP}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
check="$here/../check_entitlements.sh"
bad="$tmp/Cadence.app"
sandbox='<key>com.apple.security.app-sandbox</key><true/>'
passed=1

"$check" "$app" >/dev/null || { echo "FAIL check_entitlements rejected the built app"; exit 1; }

fresh() { rm -rf "$bad"; ditto "$app" "$bad"; }
sign_app() {
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>%s</dict></plist>\n' "$1" > "$tmp/ent.plist"
  codesign --force --sign - --options runtime --entitlements "$tmp/ent.plist" "$bad" 2>/dev/null
}
# expect NAME MESSAGE: the check must fail and say why.
expect() {
  local out
  if out="$("$check" "$bad" 2>&1)"; then echo "FAIL check_entitlements passed: $1"; exit 1; fi
  grep -q "$2" <<<"$out" || { echo "FAIL $1: expected '$2', got: $out"; exit 1; }
  passed=$((passed + 1))
}

exact='does not carry exactly'
fresh; sign_app "$sandbox<key>com.apple.security.network.client</key><true/>"; expect "a network key" 'has a network key'
fresh; sign_app '<key>com.apple.security.files.user-selected.read-write</key><true/>'; expect "no sandbox" "$exact"
fresh; sign_app "$sandbox"; expect "the store exception missing" "$exact"
fresh; sign_app "$sandbox<key>com.apple.security.temporary-exception.sbpl</key><string>(allow network*)</string>"; expect "an sbpl exception" "$exact"
fresh; printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>\n' > "$tmp/h.plist"
codesign --force --sign - --options runtime --entitlements "$tmp/h.plist" "$bad/Contents/Helpers/cadence" 2>/dev/null
codesign --force --sign - --options runtime --entitlements "$here/../../App/Cadence.entitlements" "$bad" 2>/dev/null
expect "helper entitlements" 'helper must have no entitlements'
fresh; codesign --force --sign - "$bad/Contents/Helpers/cadence" 2>/dev/null
codesign --force --sign - --options runtime --entitlements "$here/../../App/Cadence.entitlements" "$bad" 2>/dev/null
expect "no helper runtime" 'no hardened runtime on cadence'
fresh; cp /usr/bin/true "$bad/Contents/Helpers/netd"
codesign --force --sign - --options runtime --entitlements "$here/../../App/Cadence.entitlements" "$bad" 2>/dev/null
expect "an extra binary" 'unexpected binary'
fresh; plutil -remove LSUIElement "$bad/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements "$here/../../App/Cadence.entitlements" "$bad" 2>/dev/null
expect "no LSUIElement" 'does not set LSUIElement'

echo "check_entitlements test: $passed passed"
