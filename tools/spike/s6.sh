#!/bin/bash
# S6: Darwin notification posted by an unsandboxed CLI reaches the sandboxed app.
set -eu
. "$(dirname "$0")/lib.sh"
spike_begin S6
make_store
LOG="$STORE/s6.log"
NAME="$PREFIX.store-changed"

build_app CadenceSpikeS6 s6_listener.swift 1 "$TMP" \
  || { result S6 FAIL "could not build the listener app"; exit 0; }
xcrun swiftc -swift-version 5 -O "$SPIKE_DIR/src/s6_post.swift" -o "$TMP/s6_post" 2>"$TMP/post.log" \
  || { tail -5 "$TMP/post.log"; result S6 FAIL "could not build the poster"; exit 0; }

run_app "$APP" --log "$LOG" --name "$NAME" &
APP_PID=$!
if ! wait_log "$LOG" '^listening' 10; then
  wait "$APP_PID" 2>/dev/null || true
  result S6 FAIL "listener never started ($(getv "$LOG" error))"; exit 0
fi
sleep 1
"$TMP/s6_post" "$NAME" >/dev/null
if wait_log "$LOG" '^received' 5; then
  result S6 PASS "a Darwin notification posted unsandboxed reached the sandboxed listener"
else
  result S6 FAIL "no delivery within 5 s (register status $(getv "$LOG" register)); fallback is polling PRAGMA data_version"
fi
wait "$APP_PID" 2>/dev/null || true
