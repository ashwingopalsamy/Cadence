#!/usr/bin/env bash
# T3.14: tools/make_sounds.swift renders the six sounds reproducibly, into valid 44.1 kHz mono CAF files under
# 700 ms, and the files committed in App/Resources/Sounds are exactly what it renders (docs/SPEC.md section 5.6).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
[ "$(uname -s)" = Darwin ] || { echo "SKIP make_sounds test: needs macOS"; exit 0; }
swift="${SWIFT:-swift}"
names="day.start capture.saved plan.committed ring.closed streak.milestone agent.logged"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL make_sounds: $*"; exit 1; }

mkdir "$tmp/a" "$tmp/b"
"$swift" "$root/tools/make_sounds.swift" "$tmp/a" >"$tmp/a.log" || fail "the renderer failed on its first run"
"$swift" "$root/tools/make_sounds.swift" "$tmp/b" >"$tmp/b.log" || fail "the renderer failed on its second run"

# Exactly the six files, and nothing else.
want="$(printf '%s.caf\n' $names | sort | tr '\n' ' ')"
for dir in a b; do
	got="$(cd "$tmp/$dir" && ls | sort | tr '\n' ' ')"
	[ "$got" = "$want" ] || fail "run $dir wrote [$got], wanted [$want]"
done

for n in $names; do
	# Reproducible: two runs are byte for byte the same.
	cmp -s "$tmp/a/$n.caf" "$tmp/b/$n.caf" || fail "$n.caf differs between two runs"
	# The committed file is the renderer's output, so a changed note table cannot ship stale audio.
	[ -f "$root/App/Resources/Sounds/$n.caf" ] || fail "App/Resources/Sounds/$n.caf is missing: run make sounds"
	cmp -s "$tmp/a/$n.caf" "$root/App/Resources/Sounds/$n.caf" || fail "App/Resources/Sounds/$n.caf is stale: run make sounds"
	# Valid for Apple's own reader: CAF, one channel, 44.1 kHz, 16-bit, under 700 ms.
	info="$(afinfo "$tmp/a/$n.caf")" || fail "afinfo cannot read $n.caf"
	printf '%s\n' "$info" | grep -q '^File type ID: *caff' || fail "$n.caf is not a CAF file"
	printf '%s\n' "$info" | grep -q '1 ch, *44100 Hz, Int16' || fail "$n.caf is not 44.1 kHz mono Int16"
	secs="$(printf '%s\n' "$info" | awk '/^estimated duration:/ {print $3}')"
	[ -n "$secs" ] || fail "afinfo gave no duration for $n.caf"
	awk -v s="$secs" 'BEGIN { exit !(s > 0.05 && s < 0.7) }' || fail "$n.caf lasts $secs s, wanted under 0.7 s"
done

echo "make_sounds test: 6 sounds reproducible, committed, valid CAF under 700 ms"
