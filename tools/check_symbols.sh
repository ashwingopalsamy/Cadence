#!/usr/bin/env bash
# The cadence binary must contain no networking (docs/SPEC.md section 13.1, CLAUDE.md hard rules).
# Fails if the binary imports socket-level calls or links a networking library or framework.
# Usage: tools/check_symbols.sh PATH_TO_CADENCE_BINARY
set -euo pipefail

bin="${1:?usage: tools/check_symbols.sh PATH_TO_CADENCE_BINARY}"
[ -x "$bin" ] || { echo "symbols: no binary at $bin" >&2; exit 1; }

fail=0
calls='socket|connect|bind|listen|accept|getaddrinfo|gethostbyname|gethostbyname2|curl_easy_init|nw_connection_create|CFSocketCreate|CFStreamCreatePairWithSocketToHost'

case "$(uname -s)" in
  Darwin)
    libs="$(otool -L "$bin" | tail -n +2)"
    if printf '%s\n' "$libs" | grep -E -q 'Network\.framework|CFNetwork\.framework|libcurl'; then
      echo "symbols: the binary links a networking library:"; printf '%s\n' "$libs" | grep -E 'Network|CFNetwork|libcurl'
      fail=1
    fi
    imports="$(nm -u "$bin" | sed 's/^_//')"
    if printf '%s\n' "$imports" | grep -E -x -q "($calls)"; then
      echo "symbols: the binary imports network calls:"; printf '%s\n' "$imports" | grep -E -x "($calls)"
      fail=1
    fi
    if printf '%s\n' "$imports" | grep -q -E 'URLSession|NWConnection'; then
      echo "symbols: the binary uses URLSession or Network.framework"
      fail=1
    fi
    ;;
  *)
    libs="$(ldd "$bin")"
    if printf '%s\n' "$libs" | grep -E -q 'FoundationNetworking|libcurl'; then
      echo "symbols: the binary links a networking library:"; printf '%s\n' "$libs" | grep -E 'FoundationNetworking|libcurl'
      fail=1
    fi
    imports="$(nm -u "$bin" | awk '{print $NF}' | sed 's/@.*//')"
    if printf '%s\n' "$imports" | grep -E -x -q "($calls)"; then
      echo "symbols: the binary imports network calls:"; printf '%s\n' "$imports" | grep -E -x "($calls)"
      fail=1
    fi
    ;;
esac

[ $fail -eq 0 ] && echo "symbols: no networking in $(basename "$bin")"
exit $fail
