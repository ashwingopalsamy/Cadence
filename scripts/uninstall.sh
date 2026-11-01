#!/usr/bin/env bash
# Unregisters the login item and agent and removes the app and the link. Your data stays.
set -euo pipefail

dest="${HOME:?}/Applications/Cadence.app"
link="$HOME/.local/bin/cadence"

# The app is the only thing that can unregister itself, so a failure keeps it for a retry.
if [ -x "$dest/Contents/MacOS/Cadence" ] && ! "$dest/Contents/MacOS/Cadence" --unregister; then
  echo "uninstall: could not unregister, so the app stays; check Login Items in System Settings and retry" >&2
  exit 1
fi
pkill -u "$(id -u)" -x Cadence 2>/dev/null || true
rm -rf "$dest"
if [ "$(readlink "$link" 2>/dev/null)" = "$dest/Contents/Helpers/cadence" ]; then rm -f "$link"; fi
echo "uninstall: removed the app; your data in ~/Library/Application Support/Cadence is untouched"
