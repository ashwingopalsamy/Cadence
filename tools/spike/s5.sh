#!/bin/bash
# S5: RegisterEventHotKey for Ctrl+Opt+K from the sandboxed app. User presses it within 20 s.
set -eu
. "$(dirname "$0")/lib.sh"
spike_begin S5
make_store
LOG="$STORE/s5.log"
if [ "${SPIKE_NO_WAIT:-0}" = 1 ]; then
  result S5 MANUAL "not run (SPIKE_NO_WAIT=1); run bash tools/spike/s5.sh"; exit 0
fi

build_app CadenceSpikeS5 s5_app.swift 1 "$TMP" \
  || { result S5 FAIL "could not build the spike app"; exit 0; }

note "Within 20 s press Control+Option+K (no Accessibility prompt should appear)."
run_app "$APP" --log "$LOG" || true

reg=$(getv "$LOG" register)
if [ -z "$reg" ]; then result S5 FAIL "app wrote no log"; exit 0; fi
if [ "$reg" != 0 ]; then result S5 FAIL "RegisterEventHotKey returned OSStatus $reg (handler status $(getv "$LOG" handler))"; exit 0; fi
if grep -q '^pressed' "$LOG"; then
  result S5 PASS "hot key registered in sandbox and press delivered"
else
  result S5 MANUAL "hot key registered (status 0) but no press seen in 20 s"
  note "1. Run bash tools/spike/s5.sh again and press Control+Option+K within 20 s."
  note "2. Paste into docs/SPIKES.md: S5 | PASS or FAIL | whether the press was delivered"
fi
