#!/usr/bin/env bash
# The cadence binary must contain no networking (docs/SPEC.md section 13.1, CLAUDE.md hard rules).
# Fails if the binary imports socket-level calls or links a networking library or framework.
# Static imports only: a symbol resolved at run time with dlsym cannot be seen here.
# Here-strings, not pipes: grep -q closes a pipe early, and pipefail would turn a match into a miss.
# Usage: tools/check_symbols.sh PATH_TO_CADENCE_BINARY
set -euo pipefail

bin="${1:?usage: tools/check_symbols.sh PATH_TO_CADENCE_BINARY}"
[ -x "$bin" ] || { echo "symbols: no binary at $bin" >&2; exit 1; }

fail=0
calls='socket|connect|connectx|sendto|recvfrom|bind|listen|accept|getaddrinfo|gethostbyname|gethostbyname2|curl_easy_init|nw_connection_create|CFSocketCreate|CFStreamCreatePairWithSocket|CFStreamCreatePairWithSocketToHost'

case "$(uname -s)" in
  Darwin)
    libs="$(otool -L "$bin" | tail -n +2)"
    if grep -E -q 'Network\.framework|CFNetwork\.framework|libcurl' <<<"$libs"; then
      echo "symbols: the binary links a networking library:"; grep -E 'Network|CFNetwork|libcurl' <<<"$libs"
      fail=1
    fi
    imports="$(nm -u "$bin" | sed 's/^_//')"
    if grep -E -x -q "($calls)" <<<"$imports"; then
      echo "symbols: the binary imports network calls:"; grep -E -x "($calls)" <<<"$imports"
      fail=1
    fi
    if grep -q -E 'URLSession|NWConnection|NSURLConnection|NSStream|CFHTTP|CFURLConnection' <<<"$imports"; then
      echo "symbols: the binary uses URLSession or Network.framework"
      fail=1
    fi
    ;;
  *)
    libs="$(ldd "$bin")"
    if grep -E -q 'FoundationNetworking|libcurl' <<<"$libs"; then
      echo "symbols: the binary links a networking library:"; grep -E 'FoundationNetworking|libcurl' <<<"$libs"
      fail=1
    fi
    imports="$(nm -u "$bin" | awk '{print $NF}' | sed 's/@.*//')"
    if grep -E -x -q "($calls)" <<<"$imports"; then
      echo "symbols: the binary imports network calls:"; grep -E -x "($calls)" <<<"$imports"
      fail=1
    fi
    ;;
esac

[ $fail -eq 0 ] && echo "symbols: no networking in $(basename "$bin")"
exit $fail
