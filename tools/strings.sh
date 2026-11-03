#!/usr/bin/env bash
# Keeps App/Resources/Localizable.xcstrings in step with the code (docs/SPEC.md sections 14.4 and 16).
#
#   tools/strings.sh write   extract every localizable string and update the catalog   (make strings)
#   tools/strings.sh check   extract again and fail when the committed catalog differs  (make strings-check)
#
# The compiler does the extraction, as Xcode does: swiftc writes one .stringsdata file per source file when it is
# given -emit-localized-strings, and `xcstringstool sync` folds those into the catalog. A SwiftUI Text("...") literal
# is a key already; anything built as a String has to be String(localized: "...") to be seen. The compiler names each
# output after its source file, and CadenceUI and CadenceApp both have a Housekeeping.swift, so each module is built
# on its own, into its own folder under build/strings, and only its own sources are read back. The builds are
# incremental: the folders are kept, and deleting one means deleting build/strings.
# The design sheets that only CadenceTokenSheet renders are left out of the catalog.
# Needs macOS and xcstringstool (Xcode). Without them it prints SKIP and exits 0, like the other macOS-only steps.
# The compiler files strings under the table Localizable, and sync matches a catalog to a table by its file name, so
# the working copy is always called Localizable.xcstrings. STRINGS_CATALOG names another catalog, for the fixture test.
set -euo pipefail

cd "$(dirname "$0")/.."
root="$(pwd)"
mode="${1:-}"
case "$mode" in write | check) ;; *) echo "usage: tools/strings.sh write|check" >&2; exit 2 ;; esac

if [ "$(uname -s)" != Darwin ] || ! xcrun --find xcstringstool >/dev/null 2>&1; then
  echo "SKIP strings: needs macOS and xcstringstool (Xcode); the catalog is not checked here"
  exit 0
fi

swift="${SWIFT:-swift}"
catalog="${STRINGS_CATALOG:-App/Resources/Localizable.xcstrings}"
work="build/strings"
sheets='/Tokens/|Specimen|/Tempo/TempoSheet\.swift$'  # matched against Sources/... paths
mkdir -p "$work"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# build NAME TARGET: compile TARGET with extraction on, into build/strings/NAME.
build() {
  local name="$1" target="$2"
  mkdir -p "$work/$name"
  if ! "$swift" build -c debug --scratch-path "$work/$name/scratch" --target "$target" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$root/$work/$name/data" \
    >"$work/$name/build.log" 2>&1; then
    tail -n 40 "$work/$name/build.log" >&2
    echo "strings: the $target build failed" >&2
    exit 1
  fi
}

# gather NAME MODULE: print the .stringsdata files of MODULE's own sources, one per line.
# Every source of the module must have one, or the extraction is partial and the catalog would lose strings.
gather() {
  local name="$1" module="$2" file src rel
  : >"$tmp/$name.present"
  for file in "$work/$name/data"/*.stringsdata; do
    [ -e "$file" ] || continue
    src="$(sed -n 's/^ *"source" *: *"\(.*\)",\{0,1\} *$/\1/p' "$file" | head -n 1)"
    case "$src" in */Sources/"$module"/*) ;; *) continue ;; esac
    rel="Sources/${src##*/Sources/}"
    [ -f "$src" ] && [ "$src" -ef "$root/$rel" ] || continue
    printf '%s\n' "$rel" >>"$tmp/$name.present"
    if ! printf '%s\n' "$rel" | grep -q -E "$sheets"; then printf '%s\n' "$file" >>"$tmp/$name.files"; fi
  done
  (cd "$root" && find "Sources/$module" -name '*.swift' | LC_ALL=C sort) >"$tmp/$name.expected"
  LC_ALL=C sort -o "$tmp/$name.present" "$tmp/$name.present"
  local missing
  missing="$(LC_ALL=C comm -13 "$tmp/$name.present" "$tmp/$name.expected")"
  if [ -n "$missing" ]; then
    printf '%s\n' "$missing" | sed 's/^/strings: no extraction for /' >&2
    echo "strings: the extraction is partial; delete build/strings and run again, and rename any file that shares its name with another module's" >&2
    exit 1
  fi
}

build ui CadenceUI
build app CadenceApp
: >"$tmp/ui.files"
: >"$tmp/app.files"
gather ui CadenceUI
gather app CadenceApp
LC_ALL=C sort "$tmp/ui.files" "$tmp/app.files" >"$tmp/kept.files"

if [ -f "$catalog" ]; then
  cp "$catalog" "$tmp/Localizable.xcstrings"
else
  printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n' >"$tmp/Localizable.xcstrings"
fi
args=()
while IFS= read -r file; do args+=(--stringsdata "$file"); done <"$tmp/kept.files"
xcrun xcstringstool sync "$tmp/Localizable.xcstrings" ${args[@]+"${args[@]}"}

case "$mode" in
  write)
    cp "$tmp/Localizable.xcstrings" "$catalog"
    echo "strings: wrote $catalog ($(xcrun xcstringstool print "$catalog" | grep -c .) keys)"
    ;;
  check)
    if [ ! -f "$catalog" ]; then
      echo "strings: $catalog does not exist: run make strings" >&2
      exit 1
    fi
    if ! diff -u "$catalog" "$tmp/Localizable.xcstrings" >"$tmp/catalog.diff"; then
      echo "strings: $catalog is out of date: run make strings" >&2
      sed -n '1,40p' "$tmp/catalog.diff" | sed 's/^/  | /' >&2
      exit 1
    fi
    echo "strings: $catalog is current ($(xcrun xcstringstool print "$catalog" | grep -c .) keys)"
    ;;
esac
