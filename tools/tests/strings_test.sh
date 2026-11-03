#!/usr/bin/env bash
# T3.19: tools/strings.sh keeps the String Catalog current. A string missing from the catalog, or left in it after the
# code dropped it, fails the check with "run make strings", and `write` brings any catalog back to what the code says.
# Works on copies of the catalog through STRINGS_CATALOG; the committed one is never touched.
# Run: bash tools/tests/strings_test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
STRINGS="$ROOT/tools/strings.sh"
COMMITTED="$ROOT/App/Resources/Localizable.xcstrings"
if [ "$(uname -s)" != Darwin ] || ! xcrun --find xcstringstool >/dev/null 2>&1; then
  echo "SKIP strings test: needs macOS and xcstringstool (Xcode)"
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
N=0
OUT=""
RC=0

# run_strings MODE CATALOG
run_strings() {
  OUT="$(STRINGS_CATALOG="$2" bash "$STRINGS" "$1" 2>&1)"
  RC=$?
}

check() {
  N=$((N + 1))
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "ok $N - $1"
  else
    FAIL=$((FAIL + 1))
    echo "not ok $N - $1"
    echo "  rc=$RC output:"
    printf '%s\n' "$OUT" | sed 's/^/  | /' | head -30
  fi
}

has() { printf '%s\n' "$OUT" | grep -q -F -e "$1"; }

# drop_key FILE KEY and add_key FILE KEY edit the catalog as text, so the rest of its layout stays as written.
drop_key() {
  python3 -I - "$1" "$2" <<'PY'
import re, sys
path, key = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
text, n = re.subn(r'\n    "' + re.escape(key) + r'" : \{\n\n    \},', "", text, count=1)
assert n == 1, key
open(path, "w", encoding="utf-8").write(text)
PY
}
add_key() {
  python3 -I - "$1" "$2" <<'PY'
import sys
path, key = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
head = '"strings" : {\n'
assert head in text
text = text.replace(head, head + '    "' + key + '" : {\n\n    },\n', 1)
open(path, "w", encoding="utf-8").write(text)
PY
}

[ -f "$COMMITTED" ]
check "the catalog is committed" $?

cp "$COMMITTED" "$TMP/current.xcstrings"
run_strings check "$TMP/current.xcstrings"
[ $RC -eq 0 ] && has "is current"
check "the committed catalog is current" $?

cp "$COMMITTED" "$TMP/missing.xcstrings"
drop_key "$TMP/missing.xcstrings" "Plan your day"
run_strings check "$TMP/missing.xcstrings"
[ $RC -ne 0 ] && has "run make strings" && has '+    "Plan your day" : {'
check "a UI string missing from the catalog fails, names the string and says run make strings" $?

cp "$COMMITTED" "$TMP/extra.xcstrings"
add_key "$TMP/extra.xcstrings" "A string no code uses"
run_strings check "$TMP/extra.xcstrings"
[ $RC -ne 0 ] && has "run make strings" && has 'A string no code uses'
check "a string the code dropped fails the check" $?

run_strings check "$TMP/absent.xcstrings"
[ $RC -ne 0 ] && has "run make strings"
check "no catalog at all fails the check" $?

run_strings write "$TMP/missing.xcstrings"
[ $RC -eq 0 ] && cmp -s "$TMP/missing.xcstrings" "$COMMITTED"
check "write restores a missing string, byte for byte" $?

run_strings write "$TMP/extra.xcstrings"
[ $RC -eq 0 ] && cmp -s "$TMP/extra.xcstrings" "$COMMITTED"
check "write drops a string the code no longer has" $?

run_strings write "$TMP/created.xcstrings"
[ $RC -eq 0 ] && cmp -s "$TMP/created.xcstrings" "$COMMITTED"
check "write creates a catalog that is the committed one" $?

run_strings write "$TMP/current.xcstrings"
[ $RC -eq 0 ] && cmp -s "$TMP/current.xcstrings" "$COMMITTED"
check "write on a current catalog changes nothing" $?

# The design sheets that CadenceTokenSheet renders are not the app's copy.
! grep -q -F '"Design tokens, %@"' "$COMMITTED"
check "the design sheets are not in the catalog" $?

OUT="$(bash "$STRINGS" bogus 2>&1)"
RC=$?
[ $RC -eq 2 ] && has "usage"
check "an unknown mode is a usage error" $?

echo "# $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
