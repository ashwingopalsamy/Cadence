#!/bin/bash
# S1: sandboxed ad-hoc app and the unsandboxed sqlite3 CLI both write one WAL database.
set -eu
. "$(dirname "$0")/lib.sh"
spike_begin S1
make_store
mkdir -p "$HOME/Applications"
DB="$STORE/spike.db"
LOG="$STORE/s1.log"

build_app CadenceSpikeS1 s1_app.swift 1 "$HOME/Applications" \
  || { result S1 FAIL "could not build the sandboxed spike app"; exit 0; }

# Create the database as the CLI would, then let both writers hammer it.
sqlite3 "$DB" "PRAGMA journal_mode=WAL; CREATE TABLE t(src TEXT, n INTEGER);" >/dev/null
(
  i=0
  while [ "$i" -lt 50 ]; do
    sqlite3 -cmd ".timeout 5000" "$DB" "INSERT INTO t VALUES('cli',$i);" >/dev/null 2>&1 || true
    i=$((i + 1)); sleep 0.02
  done
) &
CLI_PID=$!
run_app "$APP" --db "$DB" --log "$LOG" || true
wait "$CLI_PID" || true

if [ ! -f "$LOG" ]; then
  result S1 FAIL "app wrote no result file (sandbox likely blocked the folder; see Console for deny lines)"; exit 0
fi
app_rows=$(sqlite3 "$DB" "SELECT count(*) FROM t WHERE src='app';" 2>/dev/null || echo 0)
cli_rows=$(sqlite3 "$DB" "SELECT count(*) FROM t WHERE src='cli';" 2>/dev/null || echo 0)
mode=$(sqlite3 "$DB" "PRAGMA journal_mode;" 2>/dev/null || echo "?")
sb=$(getv "$LOG" sandboxed)
if [ "$(getv "$LOG" status)" = ok ] && [ "$app_rows" = 50 ] && [ "$cli_rows" = 50 ]; then
  result S1 PASS "sandboxed app and CLI both wrote (app=$app_rows cli=$cli_rows, journal=$mode, sandbox-env=$sb)"
else
  result S1 FAIL "app=$app_rows cli=$cli_rows journal=$mode sandbox-env=$sb app-status=$(getv "$LOG" status) $(getv "$LOG" error)"
fi
