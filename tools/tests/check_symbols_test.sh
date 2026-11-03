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
# A long import list must not hide an early match behind a closed pipe. The padding sorts after socket.
{
  printf '#include <sys/socket.h>\n'
  i=0
  while [ "$i" -lt 6000 ]; do
    printf '__attribute__((weak)) extern void zzzz_padding_symbol_with_a_long_name_%d(void);\n' "$i"
    i=$((i + 1))
  done
  printf 'void *table[] = {\n'
  i=0
  while [ "$i" -lt 6000 ]; do printf 'zzzz_padding_symbol_with_a_long_name_%d,\n' "$i"; i=$((i + 1)); done
  printf '};\nint main(void){return socket(AF_INET,SOCK_STREAM,0)<0 && table[0];}\n'
} > "$tmp/big.c"
"$cc" -w -o "$tmp/big" "$tmp/big.c" $([ "$(uname -s)" = Darwin ] && echo -Wl,-undefined,dynamic_lookup)
if "$here/../check_symbols.sh" "$tmp/big" >/dev/null; then echo "FAIL check_symbols missed socket in a long import list"; exit 1; fi
echo "check_symbols test: 3 passed"
