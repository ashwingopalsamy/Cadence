#!/bin/bash
# S4: idle time and workspace notifications inside the sandbox.
# `bash s4.sh watch` runs the lock/unlock part by hand (45 s).
set -eu
. "$(dirname "$0")/lib.sh"
spike_begin S4
make_store
LOG="$STORE/s4.log"

build_app CadenceSpikeS4 s4_app.swift 1 "$TMP" \
  || { result S4 FAIL "could not build the spike app"; exit 0; }

if [ "${1:-}" = watch ]; then
  note "Within 45 s: lock the screen (Ctrl+Cmd+Q), unlock it, then let the display sleep and wake it."
  run_app "$APP" --log "$LOG" --watch 45 || true
  note "Events seen (names only):"
  { grep '^event=' "$LOG" 2>/dev/null || echo "event=(none)"; } | sed 's/^event=/    /'
  result S4 MANUAL "watch run finished; paste the event list above into docs/SPIKES.md and mark PASS if lock and unlock both appear"
  exit 0
fi

note "Do not touch the mouse or keyboard for the next 6 seconds."
run_app "$APP" --log "$LOG" || true
if [ ! -f "$LOG" ]; then result S4 FAIL "app wrote no log (sandbox blocked it?)"; exit 0; fi

aa=$(getv "$LOG" any_a); ab=$(getv "$LOG" any_b)
na=$(getv "$LOG" null_a); nb=$(getv "$LOG" null_b)
sub=$(getv "$LOG" subscribed)
if [ -z "$aa" ] || [ -z "$ab" ]; then result S4 FAIL "no idle samples were logged"; exit 0; fi
note "idle(any input) $aa -> $ab; idle(.null) $na -> $nb"

if awk -v a="$aa" -v b="$ab" 'BEGIN{exit !(b-a>=2.0)}'; then
  result S4 PASS "idle any-input ${aa}s -> ${ab}s over 3 s in sandbox; subscribed=$sub; lock/unlock part is manual: bash tools/spike/s4.sh watch"
  if awk -v a="$na" -v b="$nb" 'BEGIN{exit !(b-a>=2.0)}'; then :; else
    note "Spec 8.4 says eventType .null; here it did not rise like 'any input'. Use CGEventType(rawValue: ~0) (kCGAnyInputEventType)."
  fi
  note "Lock/unlock steps: 1. run bash tools/spike/s4.sh watch  2. lock and unlock within 45 s  3. paste the event list into docs/SPIKES.md"
elif awk -v a="$aa" -v b="$ab" 'BEGIN{exit !(b<a)}'; then
  result S4 MANUAL "input was detected during the sample (idle $aa -> $ab); rerun and keep hands off"
else
  # Something produced input during the sample. Name the kind with the smallest idle time.
  src=""; best=""
  for k in mouse key flags scroll click tablet; do
    v=$(getv "$LOG" "kind_$k")
    [ -n "$v" ] || continue
    if [ -z "$best" ] || awk -v v="$v" -v b="$best" 'BEGIN{exit !(v<b)}'; then best="$v"; src="$k"; fi
  done
  note "idle by kind:$(for k in mouse key flags scroll click tablet; do printf ' %s=%s' "$k" "$(getv "$LOG" "kind_$k")"; done)"
  if [ -n "$src" ] && awk -v b="$best" 'BEGIN{exit !(b<2.0)}'; then
    result S4 MANUAL "input of kind '$src' arrived during the hands-off sample (idle $aa -> $ab). Rerun hands off; if it repeats, an app (a mouse mover, remote control or MDM agent) posts '$src' events and presence would always look active"
  else
    result S4 FAIL "idle did not increase without input ($aa -> $ab) and no single kind explains it"
  fi
fi
