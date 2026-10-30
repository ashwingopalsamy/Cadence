#!/bin/bash
# S3: notification with a text-input action from the ad-hoc app. Needs a human; waits 60 s.
set -eu
. "$(dirname "$0")/lib.sh"
spike_begin S3
make_store
LOG="$STORE/s3.log"
if [ "${SPIKE_NO_WAIT:-0}" = 1 ]; then
  result S3 MANUAL "not run (SPIKE_NO_WAIT=1); run bash tools/spike/s3.sh"; exit 0
fi

build_app CadenceSpikeS3 s3_app.swift 1 "$TMP" \
  || { result S3 FAIL "could not build the spike app"; exit 0; }

note "Within 60 s:"
note "1. If macOS asks to allow notifications for CadenceSpikeS3, click Allow."
note "2. A notification appears top right. Hover it, click Options (or right-click) and choose 'Add a line...'."
note "3. Type a few letters and press Return. (Turn off Do Not Disturb / Focus first.)"
run_app "$APP" --log "$LOG" &
APP_PID=$!
wait_log "$LOG" '^(text=|auth=denied|error=)' 60 || true
wait "$APP_PID" 2>/dev/null || true

if grep -q '^text=' "$LOG" 2>/dev/null; then
  n=$(getv "$LOG" text | wc -c | tr -d ' ')
  result S3 PASS "text-input action delivered $((n - 1)) typed characters to the ad-hoc app"
elif grep -q '^auth=denied' "$LOG" 2>/dev/null; then
  result S3 FAIL "notification authorisation denied ($(getv "$LOG" autherr))"
elif grep -q '^error=' "$LOG" 2>/dev/null; then
  result S3 FAIL "$(getv "$LOG" error)"
else
  result S3 MANUAL "notification posted=$(grep -c '^posted' "$LOG" 2>/dev/null || echo 0) but no typed text arrived in 60 s"
  note "Paste into docs/SPIKES.md: S3 | PASS or FAIL | whether the banner showed an 'Add a line...' action and the text arrived"
fi
