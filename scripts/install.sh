#!/usr/bin/env bash
# Installs to ~/Applications and ~/.local/bin, then opens the app once. No admin at any step.
set -euo pipefail

cd "$(dirname "$0")/.."
src="build/Cadence.app"
dest="${HOME:?}/Applications/Cadence.app"
staged="$HOME/Applications/.Cadence.app.new"
link="$HOME/.local/bin/cadence"
me="$(id -u)"
[ -d "$src" ] || { echo "install: no $src; run make app" >&2; exit 1; }

# Stage and verify first, so a failed copy leaves the installed app and the link as they were.
mkdir -p "$HOME/Applications" "$(dirname "$link")"
rm -rf "$staged"
ditto "$src" "$staged"
codesign --verify --deep --strict "$staged"

# The running copy holds the single-instance lock, so it has to be gone before the new one opens.
pkill -u "$me" -x Cadence 2>/dev/null || true
tries=0
while pgrep -u "$me" -x Cadence >/dev/null; do
  tries=$((tries + 1))
  if [ "$tries" -gt 100 ]; then rm -rf "$staged"; echo "install: Cadence did not quit; nothing changed" >&2; exit 1; fi
  sleep 0.1
done

rm -rf "$dest"
mv "$staged" "$dest"
ln -sfn "$dest/Contents/Helpers/cadence" "$link"
open "$dest"
echo "install: $dest, $link"
