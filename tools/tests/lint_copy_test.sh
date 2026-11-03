#!/usr/bin/env bash
# T3.19, T4.10: fixture tests for tools/lint_copy.sh. Each test writes Swift files, a string catalog or an Info.plist into
# a throwaway folder and runs the lint on them, so every rule is shown to fire and clean code is shown to pass.
# Run: bash tools/tests/lint_copy_test.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../lint_copy.sh"
CORE_RULES="$HERE/../../Sources/CadenceCore/Day/DayStory.swift"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
N=0
OUT=""
RC=0
DIR=""

new_dir() {
  DIR="$ROOT/d$N"
  mkdir -p "$DIR"
}

# lint args...  (stdout and stderr into OUT, status into RC)
lint() {
  OUT="$(bash "$LINT" "$@" 2>&1)"
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
    printf '%s\n' "$OUT" | sed 's/^/  | /'
  fi
}

has() { printf '%s\n' "$OUT" | grep -q -F -e "$1"; }

# Prints a Swift file made of the lines given as arguments.
swift_file() {
  local name="$1"
  shift
  mkdir -p "$(dirname "$DIR/$name")"
  printf '%s\n' "$@" > "$DIR/$name"
}

EN=$'\xe2\x80\x93'
EM=$'\xe2\x80\x94'

REPO=""

# A throwaway repository: the lint script in tools/ (so it finds its own root), and Core's real DayStory.swift, which
# holds CopyRules. Each file a test adds goes under $REPO with repo_file.
new_repo() {
  REPO="$DIR/repo"
  mkdir -p "$REPO/tools" "$REPO/Sources/CadenceCore/Day" "$REPO/App/Resources"
  cp "$LINT" "$REPO/tools/lint_copy.sh"
  cp "$CORE_RULES" "$REPO/Sources/CadenceCore/Day/DayStory.swift"
}

# repo_file NAME LINES...  writes $REPO/NAME
repo_file() {
  local name="$1"
  shift
  mkdir -p "$(dirname "$REPO/$name")"
  printf '%s\n' "$@" > "$REPO/$name"
}

# lint_repo  runs the lint with no paths, from inside the throwaway repository.
lint_repo() {
  OUT="$(cd "$REPO" && bash tools/lint_copy.sh 2>&1)"
  RC=$?
}

# ---------------------------------------------------------------- tests

test_clean() {
  swift_file Clean.swift \
    'import SwiftUI' \
    '// A comment may say score, missed, productivity and you failed, and hold an em dash '"$EM"' or an en dash '"$EN" \
    '/// So may a doc comment '"$EM" \
    '/* a block comment '"$EN"' score' \
    '   /* nested, productivity '"$EM"' */' \
    '   still a comment: you failed */' \
    'let score = 1' \
    'let missed = score + 1' \
    'func productivityBoost() -> Int { missed }' \
    'enum Kind { case score, missed }' \
    'let ok = "1 - 28 Oct"' \
    'let unknown = "-"' \
    'let bound = "≥ 3"' \
    'let words = ["Dismissed 2 entries", "scored", "rescore", "scores", "missing", "failed", "You tried"]' \
    'let api = "http://example.com/path // not a comment"  // this tail comment has a dash '"$EM" \
    'let raw = #"say "hello" \(not interpolation)"#' \
    'let many = """' \
    '    Line one' \
    '    "quoted" line two' \
    '    """' \
    'let interpolated = "Done, \(done) of \(planned)"' \
    'let nested = "A \(flag ? "yes" : "no") b"' \
    'let plain = "ACME"' \
    '#Preview {' \
    '    Text("Preview '"$EM"' score")' \
    '}' \
    '#Preview("named") { Text("you failed '"$EN"'") }' \
    'struct Last { let after = "still scanned" }'
  lint "$DIR"
  [ $RC -eq 0 ] && has "lint_copy: clean (1 files)"
  check "clean code passes, comments identifiers and previews are ignored" $?
}

test_en_dash() {
  swift_file A.swift 'import SwiftUI' '' 'let a = "5 '"$EN"' 10"'
  lint "$DIR"
  [ $RC -eq 1 ] && has "A.swift:3: en dash (U+2013)" && has "lint_copy: 1 finding(s)"
  check "an en dash in a literal fails with file:line and the rule" $?
}

test_em_dash() {
  swift_file A.swift 'let a = "Done '"$EM"' sealed"'
  lint "$DIR"
  [ $RC -eq 1 ] && has "A.swift:1: em dash (U+2014)"
  check "an em dash in a literal fails with file:line and the rule" $?
}

test_escapes() {
  swift_file A.swift 'let a = "x\u{2014}y"' 'let b = "x\u{2013}y"' 'let c = "x\u{002014}y"' 'let d = #"x\#u{2013}y"#' \
    'let e = "x\u{2D}y"'
  lint "$DIR"
  local ok=1
  [ $RC -eq 1 ] && has "A.swift:1: em dash" && has "A.swift:2: en dash" && has "A.swift:3: em dash" &&
    has "A.swift:4: en dash" && ! has "A.swift:5" && has "lint_copy: 4 finding(s)" && ok=0
  check "unicode escapes that spell an en or em dash fail, a hyphen escape passes" $ok
}

test_banned_words() {
  local words word ok=0 text
  words="$(sed -n 's/.*static let banned = \[\(.*\)\].*/\1/p' "$CORE_RULES" | tr -d '"' | tr ',' '\n' | sed 's/^ *//; s/ *$//')"
  [ -n "$words" ] || ok=1
  while IFS= read -r word; do
    [ -n "$word" ] || continue
    swift_file A.swift "let a = \"Your $word today\""
    lint "$DIR"
    if ! { [ $RC -eq 1 ] && has "A.swift:1: banned word \"$word\""; }; then
      ok=1
      echo "  missing: $word"
    fi
    text="$(printf '%s' "$word" | tr '[:lower:]' '[:upper:]')"
    swift_file A.swift "let a = \"$text\""
    lint "$DIR"
    if ! { [ $RC -eq 1 ] && has "banned word \"$word\""; }; then
      ok=1
      echo "  upper case missed: $word"
    fi
  done <<< "$words"
  [ "$(printf '%s\n' "$words" | grep -c .)" -ge 4 ] || ok=1
  check "every word in CopyRules.banned fails, in any case" $ok
}

test_phrase() {
  swift_file A.swift 'let a = "You failed to plan"' 'let b = "you, failed"' 'let c = "You \(who) failed"' 'let d = "you tried and it failed"'
  lint "$DIR"
  local ok=1
  [ $RC -eq 1 ] && has "A.swift:1: banned word \"you failed\"" && has "A.swift:2: banned word \"you failed\"" &&
    ! has "A.swift:3" && ! has "A.swift:4" && ok=0
  check "the phrase you failed fails, its words apart do not" $ok
}

test_whole_words() {
  swift_file A.swift 'let a = ["Dismissed", "scored", "rescore", "scorecard", "missedly", "unproductivity"]'
  lint "$DIR"
  [ $RC -eq 0 ]
  check "a banned word inside a longer word passes" $?
}

test_interpolation() {
  swift_file A.swift \
    'let a = "ok \(count) '"$EM"' tail"' \
    'let b = "A \(flag ? "score" : "x") b"' \
    'let c = "A \(flag ? "x '"$EN"'" : "y") b"' \
    'let d = "A \(flag ? "x" : "y") you failed"' \
    'let e = "clean \(call("also clean"))"'
  lint "$DIR"
  local ok=1
  [ $RC -eq 1 ] && has "A.swift:1: em dash" && has "A.swift:2: banned word \"score\"" && has "A.swift:3: en dash" &&
    has "A.swift:4: banned word" && ! has "A.swift:5" && has "lint_copy: 4 finding(s)" && ok=0
  check "interpolated and nested literals are scanned on their own lines" $ok
}

test_multiline() {
  swift_file A.swift \
    'let a = """' \
    '    first line' \
    '    second '"$EM"' line' \
    '    third line says score' \
    '    """' \
    'let b = "after '"$EN"'"'
  lint "$DIR"
  local ok=1
  [ $RC -eq 1 ] && has "A.swift:3: em dash" && has "A.swift:4: banned word \"score\"" && has "A.swift:6: en dash" && ok=0
  check "a hit inside a multi-line literal reports its own line" $ok
}

test_raw() {
  swift_file A.swift \
    'let a = #"a "quoted" word"#' \
    'let b = ##"a "#" word '"$EM"'"##' \
    'let c = #"a \#(x) " '"$EN"'"#' \
    'let d = "after"'
  lint "$DIR"
  local ok=1
  [ $RC -eq 1 ] && has "A.swift:2: em dash" && has "A.swift:3: en dash" && ! has "A.swift:1" && ! has "A.swift:4" && ok=0
  check "raw literals keep their own delimiters" $ok
}

test_comment_markers() {
  swift_file A.swift \
    'let url = "https://example.com/a//b"' \
    'let hit = "first '"$EM"'"  // trailing comment' \
    'let slash = "/* not a comment"' \
    'let hit2 = "second '"$EN"'"'
  lint "$DIR"
  [ $RC -eq 1 ] && has "A.swift:2: em dash" && has "A.swift:4: en dash" && has "lint_copy: 2 finding(s)"
  check "comment markers inside literals hide nothing" $?
}

test_preview() {
  swift_file A.swift \
    '#Preview {' \
    '    VStack { Text("a '"$EM"'") }' \
    '}' \
    'let hit = "b '"$EN"'"' \
    '#Preview("with a title") {' \
    '    Text("c score")' \
    '}'
  lint "$DIR"
  [ $RC -eq 1 ] && has "A.swift:4: en dash" && ! has "A.swift:2" && ! has "A.swift:6" && has "lint_copy: 1 finding(s)"
  check "#Preview bodies are skipped and the code after them is scanned" $?
}

test_test_files_skipped() {
  swift_file Sources/Foo.swift 'let a = "ok"'
  swift_file Sources/FooTests.swift 'let a = "x '"$EM"'"'
  swift_file Tests/Bar.swift 'let a = "x '"$EN"'"'
  lint "$DIR"
  [ $RC -eq 0 ] && has "lint_copy: clean (1 files)"
  check "test files and Tests folders are not scanned" $?
}

test_files_and_dirs() {
  swift_file Deep/Er/A.swift 'let a = "x '"$EM"'"'
  swift_file Deep/B.swift 'let b = "fine"'
  printf 'let c = "x %s"\n' "$EN" > "$DIR/notes.txt"
  lint "$DIR"
  local ok=1
  [ $RC -eq 1 ] && has "Deep/Er/A.swift:1:" && has "lint_copy: 1 finding(s)" && ! has "notes.txt" && ok=0
  check "folders are walked and only .swift files are read" $ok
  lint "$DIR/Deep/B.swift"
  [ $RC -eq 0 ]
  check "a single file can be named" $?
}

test_output_is_short() {
  swift_file A.swift 'let a = "SECRETSURROUNDINGS '"$EM"' MOREWORDS"'
  lint "$DIR"
  [ $RC -eq 1 ] && ! has "SECRETSURROUNDINGS" && ! has "MOREWORDS"
  check "the report never echoes the literal" $?
}

test_rules_file() {
  printf 'public enum CopyRules {\n    public static let banned = ["foo", "bar baz"]\n}\n' > "$DIR/rules.swift"
  mkdir -p "$DIR/src"
  swift_file src/A.swift 'let a = "has FOO"' 'let b = "bar, baz"' 'let c = "score is fine here"'
  lint --rules "$DIR/rules.swift" "$DIR/src"
  local ok=1
  [ $RC -eq 1 ] && has "A.swift:1: banned word \"foo\"" && has "A.swift:2: banned word \"bar baz\"" && ! has "A.swift:3" && ok=0
  check "the banned list comes from the CopyRules source it is given" $ok
}

test_rules_missing() {
  swift_file A.swift 'let a = "ok"'
  printf 'enum Nothing {}\n' > "$DIR/rules.swift"
  lint --rules "$DIR/rules.swift" "$DIR/A.swift"
  local ok=1
  [ $RC -eq 2 ] && has "cannot read CopyRules.banned" && ok=0
  check "a rules file without the list is an error, never a silent pass" $ok
  lint --rules "$DIR/absent.swift" "$DIR/A.swift"
  [ $RC -eq 2 ] && has "cannot read CopyRules.banned"
  check "a missing rules file is an error" $?
}

test_core_list_is_read() {
  # The default rules are the real CopyRules in Core, so the lint and CopyRules cannot drift.
  swift_file A.swift 'let a = "ok"'
  lint "$DIR"
  [ $RC -eq 0 ] && grep -q 'static let banned = \[' "$CORE_RULES"
  check "the default rules file is Core's CopyRules and it is readable" $?
}

test_unterminated() {
  swift_file A.swift 'let a = "never closed' 'let b = 1'
  lint "$DIR"
  [ $RC -eq 1 ] && has "A.swift:1: cannot parse"
  check "a literal the lint cannot parse fails loudly" $?
}

test_no_such_path() {
  lint "$DIR/absent"
  [ $RC -eq 2 ] && has "no such file or folder"
  check "a path that does not exist is a usage error" $?
}

test_default_roots() {
  # With no paths the lint reads the four source folders, the string catalog and Info.plist, and passes on the committed tree.
  OUT="$(cd "$ROOT" && bash "$LINT" 2>&1)"
  RC=$?
  [ $RC -eq 0 ] && has "lint_copy: clean ("
  check "with no paths it scans the repository's Core, UI, app and CLI sources, the string catalog and Info.plist" $?
}

test_core_is_scanned() {
  new_repo
  lint_repo
  [ $RC -eq 0 ] && has "lint_copy: clean (1 files)"
  check "Core's real CopyRules declarations are exempt, so the tree stays clean" $?
  repo_file Sources/CadenceCore/Day/Copy.swift 'let a = "Done '"$EM"' sealed"' 'let b = "Your score today"'
  lint_repo
  local ok=1
  [ $RC -eq 1 ] && has "Sources/CadenceCore/Day/Copy.swift:1: em dash" &&
    has "Sources/CadenceCore/Day/Copy.swift:2: banned word \"score\"" && has "lint_copy: 2 finding(s)" && ok=0
  check "with no paths the lint reads Sources/CadenceCore too" $ok
}

test_core_ignores_comments_and_identifiers() {
  new_repo
  repo_file Sources/CadenceCore/Plain.swift \
    '// score, missed and productivity in a comment '"$EM" \
    'public let score = 1' \
    'public func missed() -> Int { score }' \
    'public let ok = "Seven of nine"'
  lint_repo
  [ $RC -eq 0 ]
  check "Core's comments and identifiers are as free as the interface's" $?
}

test_copy_rules_exemption_is_only_that_declaration() {
  new_repo
  repo_file Sources/CadenceCore/Rules.swift \
    'public enum CopyRules {' \
    '    public static let banned = ["productivity", "score", "missed", "you failed"]' \
    '    public static func allows(_ text: String) -> Bool {' \
    '        guard !text.contains("\u{2013}"), !text.contains("\u{2014}"), !text.contains("you failed") else { return false }' \
    '        return !text.contains("score")' \
    '    }' \
    '}' \
    'enum Other { static let words = ["your score"] }' \
    'enum CopyRulesMore { static let a = "missed it" }' \
    'let after = "5 '"$EN"' 10"' \
    'struct CopyRulesHolder { let a = "productivity" }'
  lint_repo
  local ok=1
  [ $RC -eq 1 ] && ! has "Rules.swift:1:" && ! has "Rules.swift:2:" && ! has "Rules.swift:4:" && ! has "Rules.swift:5:" &&
    has "Rules.swift:8: banned word \"score\"" && has "Rules.swift:9: banned word \"missed\"" && has "Rules.swift:10: en dash" &&
    has "Rules.swift:11: banned word \"productivity\"" && has "lint_copy: 4 finding(s)" && ok=0
  check "only the CopyRules enum is exempt, and scanning resumes after it" $ok
  new_repo
  repo_file Sources/CadenceCore/Rules.swift \
    'public enum CopyRules: Sendable' \
    '{' \
    '    public static let banned = ["score"]' \
    '}' \
    'let a = "score"'
  lint_repo
  [ $RC -eq 1 ] && ! has "Rules.swift:3:" && has "Rules.swift:5: banned word \"score\"" && has "lint_copy: 1 finding(s)"
  check "the exemption holds when the brace is on its own line" $?
}

# catalog LINES...  writes App/Resources/Localizable.xcstrings in the shape xcstringstool writes it.
catalog() { repo_file App/Resources/Localizable.xcstrings '{' '  "sourceLanguage" : "en",' '  "strings" : {' "$@" '  },' '  "version" : "1.0"' '}'; }

test_catalog_clean() {
  new_repo
  catalog \
    '    "Plan your day" : {' \
    '' \
    '    },' \
    '    "Done, %lld of %lld" : {' \
    '      "localizations" : {' \
    '        "en" : {' \
    '          "stringUnit" : {' \
    '            "state" : "new",' \
    '            "value" : "Done, %1$lld of %2$lld"' \
    '          }' \
    '        }' \
    '      }' \
    '    },' \
    '    "Range" : {' \
    '      "comment" : "A note for translators, not copy: score and missed '"$EM"' here are fine",' \
    '      "extractionState" : "manual"' \
    '    },' \
    '    "You %@ failed" : {' \
    '' \
    '    }'
  lint_repo
  [ $RC -eq 0 ] && has "lint_copy: clean (2 files)"
  check "a clean string catalog passes, translator comments and format specifiers are not copy" $?
}

test_catalog_keys_and_values() {
  new_repo
  catalog \
    '    "Your score today" : {' \
    '' \
    '    },' \
    '    "Sealed" : {' \
    '      "localizations" : {' \
    '        "en" : {' \
    '          "stringUnit" : {' \
    '            "state" : "translated",' \
    '            "value" : "Sealed '"$EM"' done"' \
    '          }' \
    '        },' \
    '        "fr" : {' \
    '          "variations" : {' \
    '            "plural" : {' \
    '              "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld day missed" } },' \
    '              "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld days, you failed" } }' \
    '            }' \
    '          }' \
    '        }' \
    '      }' \
    '    },' \
    '    "Fine" : {' \
    '' \
    '    }'
  lint_repo
  local ok=1
  [ $RC -eq 1 ] && has "App/Resources/Localizable.xcstrings:4: banned word \"score\"" &&
    has "Localizable.xcstrings:12: em dash" && has "Localizable.xcstrings:18: banned word \"missed\"" &&
    has "Localizable.xcstrings:19: banned word \"you failed\"" && has "lint_copy: 4 finding(s)" && ok=0
  check "a catalog key and every value, plural forms included, fail with file:line and the rule" $ok
}

test_catalog_format_specifier_breaks_a_phrase() {
  new_repo
  catalog '    "You %@ failed" : {' '' '    },' '    "You %1$lld failed" : {' '' '    },' '    "You failed" : {' '' '    }'
  lint_repo
  [ $RC -eq 1 ] && has "Localizable.xcstrings:10: banned word \"you failed\"" && ! has "xcstrings:4:" && ! has "xcstrings:7:" &&
    has "lint_copy: 1 finding(s)"
  check "a format specifier ends a phrase, as an interpolation does in Swift" $?
}

test_catalog_escapes_and_unreadable() {
  new_repo
  catalog '    "5 \u2013 10" : {' '' '    },' '    "A \"quoted\" word" : {' '' '    }'
  lint_repo
  [ $RC -eq 1 ] && has "Localizable.xcstrings:4: en dash" && has "lint_copy: 1 finding(s)"
  check "a JSON unicode escape that spells a dash fails" $?
  repo_file App/Resources/Localizable.xcstrings '{ "strings" : {'
  lint_repo
  [ $RC -eq 1 ] && has "Localizable.xcstrings:1: cannot parse"
  check "a catalog the lint cannot parse fails loudly" $?
}

test_catalog_can_be_named() {
  new_repo
  catalog '    "Score" : {' '' '    }'
  lint "$REPO/App/Resources/Localizable.xcstrings"
  [ $RC -eq 1 ] && has "Localizable.xcstrings:4: banned word \"score\""
  check "a catalog named on the command line is read" $?
  lint "$REPO/App/Resources"
  [ $RC -eq 0 ] && has "lint_copy: clean (0 files)"
  check "a folder walk still reads only .swift files" $?
}

test_plist_values() {
  new_repo
  repo_file App/Info.plist \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' \
    '<dict>' \
    '  <key>CFBundleName</key>' \
    '  <string>Cadence</string>' \
    '  <key>LSApplicationCategoryType</key>' \
    '  <string>public.app-category.productivity</string>' \
    '  <key>NSAppleEventsUsageDescription</key>' \
    '  <string>Cadence reads your score &amp; more '"$EM"' never</string>' \
    '  <key>score</key>' \
    '  <string>Fine</string>' \
    '  <key>LSUIElement</key>' \
    '  <true/>' \
    '  <key>Nested</key>' \
    '  <dict>' \
    '    <key>Items</key>' \
    '    <array>' \
    '      <string>It was missed</string>' \
    '    </array>' \
    '  </dict>' \
    '</dict>' \
    '</plist>'
  lint_repo
  local ok=1
  [ $RC -eq 1 ] && has "App/Info.plist:10: banned word \"score\"" && has "App/Info.plist:10: em dash" &&
    has "App/Info.plist:19: banned word \"missed\"" && ! has "Info.plist:8:" && ! has "Info.plist:11:" &&
    has "lint_copy: 3 finding(s)" && ok=0
  check "Info.plist string values are read, its keys and the app category identifier are not" $ok
}

test_plist_clean_and_unreadable() {
  new_repo
  cp "$HERE/../../App/Info.plist" "$REPO/App/Info.plist"
  lint_repo
  [ $RC -eq 0 ] && has "lint_copy: clean (2 files)"
  check "the repository's own Info.plist passes" $?
  repo_file App/Info.plist '<plist><dict><key>A</key>'
  lint_repo
  [ $RC -eq 1 ] && has "Info.plist:1: cannot parse"
  check "an Info.plist the lint cannot parse fails loudly" $?
  repo_file App/Info.plist '<plist version="1.0"><dict><key>A</key><string>x '"$EN"' y</string></dict></plist>'
  lint "$REPO/App/Info.plist"
  [ $RC -eq 1 ] && has "Info.plist:1: en dash"
  check "an Info.plist named on the command line is read" $?
}

for fn in test_core_is_scanned test_core_ignores_comments_and_identifiers test_copy_rules_exemption_is_only_that_declaration \
  test_catalog_clean test_catalog_keys_and_values test_catalog_format_specifier_breaks_a_phrase \
  test_catalog_escapes_and_unreadable test_catalog_can_be_named test_plist_values test_plist_clean_and_unreadable \
  test_clean test_en_dash test_em_dash test_escapes test_banned_words test_phrase test_whole_words \
  test_interpolation test_multiline test_raw test_comment_markers test_preview test_test_files_skipped \
  test_files_and_dirs test_output_is_short test_rules_file test_rules_missing test_core_list_is_read \
  test_unterminated test_no_such_path test_default_roots; do
  new_dir
  "$fn"
done

echo "# $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
