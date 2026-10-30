#!/usr/bin/env bash
# Tests for tools/guard.sh. Each test builds a throwaway git repo.
# Run: bash tools/tests/guard_test.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/../guard.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
N=0
OUT=""
RC=0

# Fake terms only.
TERM1="globexcorp"
TERM2="initech-internal.example"

new_repo() {
  REPO="$ROOT/r$N"
  mkdir -p "$REPO"
  (
    cd "$REPO" || exit 1
    git init -q .
    git config user.email t@example.com
    git config user.name t
    git config commit.gpgsign false
  )
  LIST="$ROOT/forbidden$N.txt"
  printf '%s\n%s\n' "$TERM1" "$TERM2" > "$LIST"
  export CADENCE_FORBIDDEN="$LIST"
}

# run_guard args...  (captures stdout+stderr into OUT, status into RC)
run_guard() {
  OUT="$(cd "$REPO" && bash "$GUARD" "$@" 2>&1)"
  RC=$?
}

stage() { (cd "$REPO" && git add -A >/dev/null 2>&1); }
commit() { (cd "$REPO" && git commit -q -m "$1" >/dev/null 2>&1); }

check() {
  # check "name" condition-result(0=true)
  N=$((N + 1))
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "ok $N - $1"
  else
    FAIL=$((FAIL + 1))
    echo "not ok $N - $1"
    echo "  rc=$RC output:"
    printf '%s\n' "$OUT" | sed 's/^/  | /'
  fi
}

has() { printf '%s\n' "$OUT" | grep -q -F -e "$1"; }
has_ci() { printf '%s\n' "$OUT" | grep -q -i -F -e "$1"; }

t() { # t "name" ; body runs in function named by $2
  new_repo
  "$2"
}

# ---------------------------------------------------------------- tests

test_clean() {
  printf 'hello\nworld\n' > "$REPO/a.txt"
  stage
  run_guard --staged
  [ $RC -eq 0 ] && has "guard: clean (1 files)"
  check "clean repo passes" $?
}

test_term_staged() {
  printf 'line one\nsee Globexcorp here\n' > "$REPO/notes.txt"
  stage
  run_guard --staged
  local ok=1
  [ $RC -eq 2 ] && has "guard: forbidden term #1 in notes.txt:2" && has "guard: 1 finding(s)" && ok=0
  check "term in staged file exits 2 with path, line and index" $ok
  printf '%s\n' "$OUT" | grep -q -i -F -e "$TERM1"
  [ $? -ne 0 ]
  check "term never printed (any case)" $?
  printf '%s\n' "$OUT" | grep -q -i -F -e "see"
  [ $? -ne 0 ]
  check "matching line content never printed" $?
}

test_term_working_only() {
  printf 'clean\n' > "$REPO/a.txt"
  stage
  printf 'clean\nglobexcorp\n' > "$REPO/a.txt"
  run_guard --staged
  [ $RC -eq 0 ]
  check "--staged scans the staged blob, not the working copy" $?
}

test_case_insensitive() {
  printf 'x INITECH-INTERNAL.EXAMPLE y\n' > "$REPO/a.txt"
  stage
  run_guard --staged
  [ $RC -eq 2 ] && has "forbidden term #2 in a.txt:1"
  check "case-insensitive match" $?
}

test_index_counting() {
  printf '# comment\n\n%s\n   \n# another\n%s\n' "$TERM1" "$TERM2" > "$LIST"
  printf 'a\nb\ninitech-internal.example\n' > "$REPO/a.txt"
  stage
  run_guard --staged
  [ $RC -eq 2 ] && has "forbidden term #2 in a.txt:3"
  check "comments and blanks ignored; index counts real terms" $?
}

test_fixed_string() {
  printf 'a.c\n' > "$LIST"
  printf 'abc\n' > "$REPO/a.txt"
  stage
  run_guard --staged
  [ $RC -eq 0 ]
  check "terms are fixed strings, not regex" $?
}

test_missing_list() {
  export CADENCE_FORBIDDEN="$ROOT/does-not-exist.txt"
  printf 'globexcorp\n' > "$REPO/a.txt"
  printf 'SQLite format 3\000rest' > "$REPO/x.bin"
  stage
  run_guard --staged
  local ok=1
  has "guard: no forbidden-terms list at $ROOT/does-not-exist.txt; term check skipped" \
    && ! has "forbidden term" && has "data file (sqlite) x.bin" && [ $RC -eq 2 ] && ok=0
  check "missing list: notice, term check skipped, other checks still run" $ok
  printf 'fine\n' > "$REPO/x.bin"
  printf 'fine\n' > "$REPO/a.txt"
  stage
  run_guard --staged
  [ $RC -eq 0 ] && has "term check skipped"
  check "missing list does not affect exit status" $?
}

test_sqlite() {
  printf 'SQLite format 3\000more bytes' > "$REPO/store.dat"
  stage
  run_guard --staged
  [ $RC -eq 2 ] && has "guard: data file (sqlite) store.dat"
  check "SQLite header file fails" $?
}

test_proof_envelope() {
  printf '{"schema":"cadence.proof/1","x":1}\n' > "$REPO/p.json"
  printf '{"cadence":"envelope/1","x":1}\n' > "$REPO/e1.json"
  printf '{"cadence": "envelope/1"}\n' > "$REPO/e2.json"
  stage
  run_guard --staged
  [ $RC -eq 2 ] && has "guard: data file (proof) p.json" \
    && has "guard: data file (envelope) e1.json" \
    && has "guard: data file (envelope) e2.json"
  check "proof and envelope files fail" $?
}

test_vectors_exempt() {
  mkdir -p "$REPO/Tests/Vectors" "$REPO/examples" "$REPO/tools/tests/fixtures"
  printf '{"schema":"cadence.proof/1"}\n' > "$REPO/Tests/Vectors/valid.json"
  printf '{"cadence":"envelope/1"}\n' > "$REPO/examples/e.json"
  printf '{"schema":"cadence.proof/1"}\n' > "$REPO/tools/tests/fixtures/p.json"
  stage
  run_guard --staged
  [ $RC -eq 0 ]
  check "data files under Tests/Vectors, examples and tools/tests pass" $?
}

# Builds secrets at runtime so this file never contains a matching literal.
test_secrets() {
  local aws gh pat slack key sk
  aws="AK""IA""ABCDEFGHIJKLMNOP"
  gh="gh""p_""abcdefghijklmnopqrstuvwxyz0123456789"
  pat="github""_pat_""abcdefghijklmnopqrstuv"
  slack="xo""xb-""1234567890-abcdef"
  key="-----BEGIN ""RSA PRIVATE KEY-----"
  sk="sk""-ant-""abcdefghijklmnopqrstuvwxyz"
  printf '%s\n' "$aws" > "$REPO/aws.txt"
  printf 'x=%s\n' "$gh" > "$REPO/gh.txt"
  printf '%s\n' "$pat" > "$REPO/pat.txt"
  printf '%s\n' "$slack" > "$REPO/slack.txt"
  printf '%s\n' "$key" > "$REPO/key.txt"
  printf 'k = %s\n' "$sk" > "$REPO/sk.txt"
  stage
  run_guard --staged
  local ok=1
  [ $RC -eq 2 ] && has "possible secret (aws-access-key) in aws.txt:1" \
    && has "possible secret (github-token) in gh.txt:1" \
    && has "possible secret (github-token) in pat.txt:1" \
    && has "possible secret (slack-token) in slack.txt:1" \
    && has "possible secret (private-key) in key.txt:1" \
    && has "possible secret (api-key) in sk.txt:1" && ok=0
  check "each secret kind is caught" $ok
  local leaked=0 s
  for s in "$aws" "$gh" "$pat" "$slack" "$key" "$sk"; do
    has "$s" && leaked=1
  done
  [ $leaked -eq 0 ]
  check "secret values are never printed" $?
}

test_allow_secret() {
  local aws
  aws="AK""IA""ABCDEFGHIJKLMNOP"
  printf 'example %s # guard:allow-secret\n' "$aws" > "$REPO/doc.md"
  stage
  run_guard --staged
  [ $RC -eq 0 ]
  check "guard:allow-secret skips the line" $?
}

test_binary_skip() {
  printf 'globexcorp\000binary' > "$REPO/blob.bin"
  stage
  run_guard --staged
  [ $RC -eq 0 ]
  check "binary file with the term is skipped for terms" $?
}

test_history() {
  printf 'initech-internal.example\n' > "$REPO/a.txt"
  stage
  commit one
  printf 'clean\n' > "$REPO/a.txt"
  stage
  commit two
  run_guard --all
  local a=$RC
  run_guard --history
  local ok=1
  [ $a -eq 0 ] && [ $RC -eq 2 ] && has "forbidden term #2 in " && has ":a.txt:1" && ok=0
  check "--history finds a term removed in a later commit" $ok
  printf '%s\n' "$OUT" | grep -q -i -F -e "$TERM2"
  [ $? -ne 0 ]
  check "--history never prints the term" $?
}

test_all_untracked() {
  printf 'a\n' > "$REPO/tracked.txt"
  stage
  commit one
  printf 'globexcorp\n' > "$REPO/untracked.txt"
  printf 'globexcorp\n' > "$REPO/ignored.txt"
  printf 'ignored.txt\n' > "$REPO/.gitignore"
  run_guard --all
  [ $RC -eq 2 ] && has "in untracked.txt:1" && ! has "ignored.txt:"
  check "--all covers untracked but not ignored files" $?
}

test_path_withheld() {
  printf 'x\n' > "$REPO/globexcorp-notes.txt"
  stage
  run_guard --staged
  local a=$RC
  local leak=0
  printf '%s\n' "$OUT" | grep -q -i -F -e "$TERM1" && leak=1
  [ $a -eq 2 ] && [ $leak -eq 0 ]
  check "a term in a file name is reported without printing it" $?
}

test_install_hooks() {
  run_guard --install-hooks
  local v
  v="$(cd "$REPO" && git config core.hooksPath)"
  [ $RC -eq 0 ] && [ "$v" = ".githooks" ] && has "core.hooksPath"
  check "--install-hooks sets core.hooksPath" $?
}

test_unknown_flag() {
  run_guard --bogus
  local ok=1
  [ $RC -eq 1 ] && has "Usage" && ok=0
  check "unknown flag exits 1 with usage" $ok
  run_guard
  [ $RC -eq 1 ]
  check "no mode exits 1" $?
  run_guard --staged --all
  [ $RC -eq 1 ]
  check "two modes exits 1" $?
  run_guard --help
  [ $RC -eq 0 ] && has "Usage"
  check "--help prints usage" $?
}

for fn in test_clean test_term_staged test_term_working_only test_case_insensitive \
  test_index_counting test_fixed_string test_missing_list test_sqlite \
  test_proof_envelope test_vectors_exempt test_secrets test_allow_secret \
  test_binary_skip test_history test_all_untracked test_path_withheld \
  test_install_hooks test_unknown_flag; do
  new_repo
  "$fn"
done

echo "# $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
