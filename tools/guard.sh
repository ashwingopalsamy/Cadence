#!/usr/bin/env bash
# Cadence guard: fails when the tree holds employer identifiers, work-log data
# files or secrets. Works with bash 3.2 and BSD or GNU grep, sed and find.
#
# Output rule: never print a forbidden term, a matching line, or any part of a
# secret. Findings carry only a kind, a term index, a path and a line number.

export LC_ALL=C

usage() {
  cat <<'USAGE'
Usage: tools/guard.sh MODE
  --staged         scan the staged blobs in the git index
  --all            scan tracked and untracked-but-not-ignored files
  --history        scan every blob reachable from any commit
  --install-hooks  set core.hooksPath to .githooks
  --help           show this help

Forbidden terms: ${CADENCE_FORBIDDEN:-$HOME/.config/cadence/forbidden.txt}
Exit codes: 0 clean, 1 usage error, 2 findings.
USAGE
}

MODE=""
for arg in "$@"; do
  case "$arg" in
    --staged|--all|--history|--install-hooks)
      if [ -n "$MODE" ]; then
        usage >&2
        exit 1
      fi
      MODE="$arg"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done
if [ -z "$MODE" ]; then
  usage >&2
  exit 1
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$ROOT" ]; then
  echo "guard: not inside a git repository" >&2
  exit 1
fi
cd "$ROOT" || exit 1

if [ "$MODE" = "--install-hooks" ]; then
  git config core.hooksPath .githooks
  echo "guard: set git config core.hooksPath to .githooks"
  exit 0
fi

FORBIDDEN="${CADENCE_FORBIDDEN:-$HOME/.config/cadence/forbidden.txt}"
TERMS=()
if [ -f "$FORBIDDEN" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      '#'*) continue ;;
    esac
    # skip blank or whitespace-only lines
    if [ -z "$(printf '%s' "$line" | tr -d ' \t')" ]; then
      continue
    fi
    TERMS[${#TERMS[@]}]="$line"
  done < "$FORBIDDEN"
else
  echo "guard: no forbidden-terms list at $FORBIDDEN; term check skipped" >&2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/guard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
CONTENT="$TMP/content"

FINDINGS=0
FILES=0

finding() {
  echo "$1"
  FINDINGS=$((FINDINGS + 1))
}

is_exempt_path() {
  case "$1" in
    Tests/Vectors/*|examples/*|tools/tests/*) return 0 ;;
  esac
  return 1
}

is_git_path() {
  case "$1" in
    .git|.git/*|*/.git|*/.git/*) return 0 ;;
  esac
  return 1
}

is_binary() {
  local total nonnul
  total="$(head -c 8000 "$1" | wc -c | tr -d ' ')"
  nonnul="$(head -c 8000 "$1" | tr -d '\000' | wc -c | tr -d ' ')"
  [ "$total" != "$nonnul" ]
}

# term_hits FILE TERM -> line numbers only
term_hits() {
  grep -a -n -i -F -e "$2" "$1" | cut -d: -f1
}

# scan LABEL PATH_FOR_EXEMPTION FILE
scan() {
  local label="$1" rel="$2" f="$3" shown idx t ln pat kind
  FILES=$((FILES + 1))

  # A forbidden term in the file name must not be echoed either.
  shown="$label"
  idx=0
  for t in "${TERMS[@]}"; do
    idx=$((idx + 1))
    if printf '%s\n' "$label" | grep -q -i -F -e "$t"; then
      finding "guard: forbidden term #$idx in a file name (path withheld)"
      shown="[withheld]"
      break
    fi
  done

  if ! is_exempt_path "$rel"; then
    if [ "$(head -c 15 "$f" | tr -d '\000')" = "SQLite format 3" ]; then
      finding "guard: data file (sqlite) $shown"
    fi
    local first
    first="$(head -n 1 "$f" | head -c 100000 | tr -d '\000')"
    if printf '%s\n' "$first" | grep -a -q -F '"cadence.proof/1"'; then
      finding "guard: data file (proof) $shown"
    fi
    if printf '%s\n' "$first" | grep -a -q -E '"cadence": ?"envelope/1"'; then
      finding "guard: data file (envelope) $shown"
    fi
  fi

  if is_binary "$f"; then
    return 0
  fi

  idx=0
  for t in "${TERMS[@]}"; do
    idx=$((idx + 1))
    while IFS= read -r ln; do
      [ -n "$ln" ] && finding "guard: forbidden term #$idx in $shown:$ln"
    done < <(term_hits "$f" "$t")
  done

  while IFS='|' read -r kind pat; do
    while IFS= read -r ln; do
      [ -n "$ln" ] && finding "guard: possible secret ($kind) in $shown:$ln"
    done < <(grep -a -n -E -e "$pat" "$f" | grep -a -v -F 'guard:allow-secret' | cut -d: -f1)
  done <<'PATTERNS'
aws-access-key|AKIA[0-9A-Z]{16}
github-token|gh[pousr]_[A-Za-z0-9]{36,}
github-token|github_pat_[A-Za-z0-9_]{22,}
slack-token|xox[abprs]-[A-Za-z0-9-]{10,}
private-key|-----BEGIN [A-Z ]*PRIVATE KEY-----
api-key|sk-(ant-)?[A-Za-z0-9_-]{20,}
PATTERNS
}

case "$MODE" in
  --staged)
    while IFS= read -r -d '' p; do
      is_git_path "$p" && continue
      git show ":$p" > "$CONTENT" 2>/dev/null || continue
      scan "$p" "$p" "$CONTENT"
    done < <(git diff --cached --name-only --diff-filter=ACMR -z)
    ;;
  --all)
    while IFS= read -r -d '' p; do
      is_git_path "$p" && continue
      [ -f "$p" ] && [ ! -L "$p" ] || continue
      scan "$p" "$p" "$p"
    done < <(git ls-files -co --exclude-standard -z)
    ;;
  --history)
    while read -r type sha path; do
      [ "$type" = "blob" ] || continue
      [ -n "$path" ] || continue
      is_git_path "$path" && continue
      git cat-file blob "$sha" > "$CONTENT" 2>/dev/null || continue
      scan "$(printf '%s' "$sha" | cut -c1-12):$path" "$path" "$CONTENT"
    done < <(git rev-list --objects --all 2>/dev/null \
      | git cat-file --batch-check='%(objecttype) %(objectname) %(rest)')
    ;;
esac

if [ "$FINDINGS" -gt 0 ]; then
  echo "guard: $FINDINGS finding(s)"
  exit 2
fi
echo "guard: clean ($FILES files)"
exit 0
