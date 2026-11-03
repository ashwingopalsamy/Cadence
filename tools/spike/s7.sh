#!/bin/bash
# S7: Apple Intelligence availability through FoundationModels.
set -eu
. "$(dirname "$0")/lib.sh"
spike_begin S7

if ! xcrun swiftc -swift-version 5 "$SPIKE_DIR/src/s7.swift" -o "$TMP/s7" 2>"$TMP/s7.log"; then
  result S7 FAIL "FoundationModels cannot be compiled with these tools: $(grep -m1 'error:' "$TMP/s7.log" | cut -c1-160)"
  exit 0
fi
out=$("$TMP/s7" 2>&1 | head -1 || true)
case "$out" in
  available) result S7 PASS "SystemLanguageModel.default is available" ;;
  *modelNotReady*) result S7 MANUAL "$out: Apple Intelligence is on but the model is still downloading; rerun later. Until then the deterministic parser is the only path" ;;
  unavailable*) result S7 FAIL "$out; fallback is the deterministic parser only" ;;
  *) result S7 FAIL "unexpected probe output: $out" ;;
esac
