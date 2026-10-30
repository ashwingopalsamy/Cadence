#!/usr/bin/env bash
# T1.5: 4 processes x 500 appends through the cadence binary must give one gapless, valid chain.
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
bin="${CADENCE_BIN:-$(cd "$root" && swift build --show-bin-path)/cadence}"
procs="${STRESS_PROCS:-4}"
count="${STRESS_COUNT:-500}"
home="$(mktemp -d)"
trap 'rm -rf "$home"' EXIT
export CADENCE_HOME="$home" CADENCE_ALLOW_DEV=1
pids=""
for p in $(seq 1 "$procs"); do
  "$bin" dev append --count "$count" --label "w$p" &
  pids="$pids $!"
done
fail=0
for pid in $pids; do wait "$pid" || fail=1; done
[ "$fail" = 0 ] || { echo "ledger stress: a writer failed"; exit 1; }
python3 "$root/tools/tests/check_db_chain.py" "$home/cadence.db" $((procs * count + 1))
mode="$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$home/cadence.db")"
[ "$mode" = "0o600" ] || { echo "ledger stress: cadence.db mode is $mode, expected 0o600"; exit 1; }
echo "ledger stress: $procs x $count appends, chain valid, store mode 0600"
