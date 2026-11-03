#!/usr/bin/env bash
# Builds build/Cadence.app and signs it ad-hoc, inside out (docs/SPEC.md section 14.3).
set -euo pipefail

cd "$(dirname "$0")/.."
prefix="${BUNDLE_PREFIX:-in.ashwingopalsamy.cadence}"
[[ "$prefix" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "bundle: BUNDLE_PREFIX may hold only letters, digits, dots and dashes" >&2; exit 1; }
app="build/Cadence.app"
contents="$app/Contents"
agent_dir="$contents/Library/LaunchAgents"
jobs_path="$HOME/Library/Application Support/Cadence/jobs"

swift build -c release --product CadenceApp
swift build -c release --product cadence
bin="$(swift build -c release --show-bin-path)"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Resources" "$agent_dir"
cp "$bin/CadenceApp" "$contents/MacOS/Cadence"
cp "$bin/cadence" "$contents/Helpers/cadence"
sed "s|@BUNDLE_ID@|$prefix|g" App/Info.plist > "$contents/Info.plist"
sed -e "s|@BUNDLE_ID@|$prefix|g" -e "s|@JOBS_PATH@|$jobs_path|g" App/Agent.plist.in > "$agent_dir/$prefix.agent.plist"
# rsync skips the .gitkeep placeholders, which would otherwise ship as sealed resources, and the String Catalog source,
# which ships compiled instead.
rsync -a --exclude '.*' --exclude '*.xcstrings' App/Resources/ "$contents/Resources/"
# The catalog compiles to <language>.lproj/Localizable.strings, and the app loads it through Bundle.main. English needs
# no table, because a key is its own English text, so a catalog with no translation yet compiles to nothing.
if xcrun --find xcstringstool >/dev/null 2>&1; then
  xcrun xcstringstool compile App/Resources/Localizable.xcstrings --output-directory "$contents/Resources"
else
  echo "bundle: SKIP String Catalog: xcstringstool not found (it comes with Xcode); strings fall back to their English keys"
fi

if xcrun --find actool >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  xcrun actool App/Cadence.icon --compile "$contents/Resources" --app-icon Cadence --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist "$tmp/icon-info.plist" --output-format human-readable-text --notices --warnings --errors
  icon_name="$(plutil -extract CFBundleIconName raw -o - "$tmp/icon-info.plist")"
  icon_file="$(plutil -extract CFBundleIconFile raw -o - "$tmp/icon-info.plist")"
  plutil -replace CFBundleIconName -string "$icon_name" "$contents/Info.plist"
  plutil -replace CFBundleIconFile -string "$icon_file" "$contents/Info.plist"
else
  echo "SKIP icon: actool needs Xcode"
fi
plutil -lint -s "$contents/Info.plist" "$agent_dir/$prefix.agent.plist"

codesign --force --sign - --options runtime --identifier "$prefix.cadence" "$contents/Helpers/cadence"
codesign --force --sign - --options runtime --entitlements App/Cadence.entitlements "$app"
codesign --verify --deep --strict "$app"
echo "bundle: $app ($prefix)"
