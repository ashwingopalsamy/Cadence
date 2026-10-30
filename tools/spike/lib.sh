# Shared helpers for the spike checks. Sourced by s1.sh .. s9.sh. bash 3.2 compatible.
# shellcheck shell=bash

SPIKE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=${BUNDLE_PREFIX:-in.ashwingopalsamy.cadence.spike}
STORE_ROOT="$HOME/Library/Application Support/CadenceSpike"
SPIKE_APPS=""   # newline-separated app bundles to delete on exit
APP=""          # last bundle built by build_app

is_macos() { [ "$(uname)" = "Darwin" ]; }

# result ID STATUS SUMMARY: the one result line a check prints.
result() { printf '%s %s %s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' ' ')"; }
note() { printf '  %s\n' "$*"; }

# Remove everything this check created. Runs on every exit path.
spike_cleanup() {
  if type spike_extra_cleanup >/dev/null 2>&1; then spike_extra_cleanup || true; fi
  local a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    pkill -f "$a/Contents/MacOS" 2>/dev/null || true
    rm -rf "$a" || true
  done <<EOT
$SPIKE_APPS
EOT
  [ -n "${STORE:-}" ] && rm -rf "$STORE" || true
  rmdir "$STORE_ROOT" 2>/dev/null || true
  [ -n "${TMP:-}" ] && rm -rf "$TMP" || true
}

# spike_begin ID: skip off macOS, otherwise make temp dir, store dir and the cleanup trap.
spike_begin() {
  SPIKE_ID=$1
  if ! is_macos; then result "$SPIKE_ID" SKIP "not macOS"; exit 0; fi
  TMP=$(mktemp -d)
  STORE="$STORE_ROOT/$(printf '%s' "$SPIKE_ID" | tr 'A-Z' 'a-z')-$$"
  trap spike_cleanup EXIT
  trap 'exit 130' INT TERM
}

make_store() { mkdir -p "$STORE"; }

# Entitlements exactly as spec 8.3, with the spike's own folder.
write_entitlements() {
  cat >"$1" <<'EOT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
<array><string>/Library/Application Support/CadenceSpike/</string></array>
</dict></plist>
EOT
}

# build_app NAME SOURCE SANDBOXED(1|0) PARENT_DIR
# Compiles src/SOURCE, assembles PARENT/NAME.app, signs it ad-hoc with the hardened runtime.
# If APP_PRESIGN is set it is called with the bundle path before signing (S2 adds the agent plist).
build_app() {
  local name=$1 src=$2 sandboxed=$3 parent=$4
  APP="$parent/$name.app"
  SPIKE_APPS="$SPIKE_APPS
$APP"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  if ! xcrun swiftc -swift-version 5 -O "$SPIKE_DIR/src/$src" -o "$APP/Contents/MacOS/$name" 2>"$TMP/swiftc.log"; then
    note "swiftc failed for $src:"
    tail -8 "$TMP/swiftc.log" | sed 's/^/    /'
    return 1
  fi
  cat >"$APP/Contents/Info.plist" <<EOT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$PREFIX.$(printf '%s' "$SPIKE_ID" | tr 'A-Z' 'a-z')</string>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOT
  if [ -n "${APP_PRESIGN:-}" ]; then "$APP_PRESIGN" "$APP"; fi
  if [ "$sandboxed" = 1 ]; then
    write_entitlements "$TMP/ent.plist"
    codesign --force --sign - --options runtime --entitlements "$TMP/ent.plist" "$APP" 2>"$TMP/codesign.log" \
      || { tail -3 "$TMP/codesign.log"; return 1; }
  else
    codesign --force --sign - --options runtime "$APP" 2>"$TMP/codesign.log" \
      || { tail -3 "$TMP/codesign.log"; return 1; }
  fi
}

# run_app APP ARGS...: launch through LaunchServices and wait for the app to exit.
run_app() { local app=$1; shift; open -W -n "$app" --args "$@"; }

# wait_log FILE REGEX SECONDS: 0 once FILE has a line matching REGEX.
wait_log() {
  local i=0
  while [ "$i" -lt "$3" ]; do
    if [ -f "$1" ] && grep -Eq "$2" "$1"; then return 0; fi
    sleep 1; i=$((i + 1))
  done
  return 1
}

# getv FILE KEY: value of the first KEY=value line, empty if none.
getv() { { grep "^$2=" "$1" 2>/dev/null || true; } | head -1 | cut -d= -f2-; }
