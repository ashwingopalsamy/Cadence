#!/usr/bin/env bash
# Proves tools/check_symbols.sh fails on a binary that imports socket calls and passes on one that does not.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cc="$(command -v clang || command -v cc || true)"
[ -n "$cc" ] || { echo "SKIP check_symbols test: no C compiler"; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '#include <sys/socket.h>\nint main(void){return socket(AF_INET,SOCK_STREAM,0)<0;}\n' > "$tmp/net.c"
printf 'int main(void){return 0;}\n' > "$tmp/plain.c"
"$cc" -o "$tmp/net" "$tmp/net.c"
"$cc" -o "$tmp/plain" "$tmp/plain.c"
if "$here/../check_symbols.sh" "$tmp/net" >/dev/null; then echo "FAIL check_symbols passed a socket binary"; exit 1; fi
"$here/../check_symbols.sh" "$tmp/plain" >/dev/null || { echo "FAIL check_symbols rejected a plain binary"; exit 1; }
echo "check_symbols test: 2 passed"
