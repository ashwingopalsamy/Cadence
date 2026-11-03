#!/usr/bin/env bash
# The copy lint (docs/SPEC.md sections 6.6 and 14.6): no en or em dash and none of the banned words in the string
# literals of the interface and the command line's output, in the words Core tells the interface (the day story), and in
# the string catalog and Info.plist the app ships.
#
#   tools/lint_copy.sh [--rules FILE] [PATH ...]
#
# PATH is a Swift file, a folder, a string catalog (.xcstrings) or an Info.plist (.plist). With none, it reads
# Sources/CadenceCore, Sources/CadenceUI, Sources/CadenceApp and Sources/cadence, then App/Resources/Localizable.xcstrings
# and App/Info.plist. A folder is walked for .swift files only.
# Comments, `#Preview` bodies and test files (a Tests folder, or a name ending in Tests.swift) are skipped, and only
# string literals are read, so identifiers such as `score` or `missed` are fine. A dash spelled as a `\u{2013}` or
# `\u{2014}` escape counts too. The banned words are read from `CopyRules.banned` in Core, the same list the
# interface tests check with `CopyRules.allows`, so the two cannot drift; --rules names another source for tests.
# The one exemption is the `enum CopyRules` declaration itself, which has to spell the words and dashes it rules out.
# A catalog is read for every key (a key is the English text unless a value replaces it) and every value, plural forms
# included, never its comments; a format specifier such as `%@` or `%1$lld` ends a phrase as an interpolation does. An
# Info.plist is read for its string values, never its keys, and not `LSApplicationCategoryType`, whose values are Apple's
# identifiers (public.app-category.productivity).
# Exit 0 clean, 1 findings, 2 usage or unreadable rules. Needs python3 only.
set -euo pipefail
LINT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export LINT_ROOT
exec "${PYTHON:-python3}" -I - "$@" <<'PY'
import html
import json
import os
import plistlib
import re
import sys

ROOT = os.environ["LINT_ROOT"]
DEFAULT_RULES = os.path.join(ROOT, "Sources/CadenceCore/Day/DayStory.swift")
DEFAULT_PATHS = [
    "Sources/CadenceCore",
    "Sources/CadenceUI",
    "Sources/CadenceApp",
    "Sources/cadence",
    "App/Resources/Localizable.xcstrings",
    "App/Info.plist",
]
EXEMPT_ENUM = re.compile(r"enum\s+CopyRules(?![A-Za-z0-9_])")
EXEMPT_PLIST_KEYS = {"LSApplicationCategoryType"}
EN, EM = "–", "—"
BARRIER = None  # an interpolation: it ends a word and breaks a phrase


def banned_phrases(path):
    try:
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
    except OSError:
        source = ""
    match = re.search(r"static\s+let\s+banned\s*(?::\s*\[String\])?\s*=\s*\[([^\]]*)\]", source)
    items = re.findall(r'"([^"\\]*)"', match.group(1)) if match else []
    if not items:
        sys.stderr.write("lint_copy: cannot read CopyRules.banned from %s\n" % path)
        sys.exit(2)
    return [item.lower().split() for item in items]


class Literal:
    __slots__ = ("chars", "offsets")

    def __init__(self):
        self.chars = []
        self.offsets = []

    def add(self, char, offset):
        self.chars.append(char)
        self.offsets.append(offset)


class ParseError(Exception):
    def __init__(self, offset, message):
        super().__init__(message)
        self.offset = offset


SIMPLE_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "0": "\0", "\\": "\\", '"': '"', "'": "'"}
IDENT = re.compile(r"[A-Za-z0-9_]")


class Scanner:
    def __init__(self, text):
        self.text = text
        self.literals = []

    def code(self, i, in_interpolation):
        """Scans code from i. Returns the index after the closing parenthesis of an interpolation, or the end."""
        text, n = self.text, len(self.text)
        parens = 0
        braces = 0
        # A #Preview body and the CopyRules enum are skipped: from the keyword to the brace that closes its body.
        preview_mark = None
        preview_depth = None
        while i < n:
            c = text[i]
            if c == "/" and text.startswith("//", i):
                j = text.find("\n", i)
                i = n if j < 0 else j
            elif c == "/" and text.startswith("/*", i):
                i = self.block_comment(i)
            elif c == '"' or (c == "#" and self.raw_start(i)):
                i = self.string(i)
            elif c == "#" and text.startswith("#Preview", i) and not (i + 8 < n and IDENT.match(text[i + 8])):
                if preview_mark is None:
                    preview_mark = len(self.literals)
                    preview_depth = None
                i += 8
            elif c == "e" and preview_mark is None and not (i > 0 and IDENT.match(text[i - 1])) and EXEMPT_ENUM.match(text, i):
                preview_mark = len(self.literals)
                preview_depth = None
                i = EXEMPT_ENUM.match(text, i).end()
            elif c == "{":
                braces += 1
                if preview_mark is not None and preview_depth is None:
                    preview_depth = braces
                i += 1
            elif c == "}":
                if preview_depth is not None and braces == preview_depth:
                    del self.literals[preview_mark:]
                    preview_mark = preview_depth = None
                braces -= 1
                i += 1
            elif c == "(":
                parens += 1
                i += 1
            elif c == ")":
                if in_interpolation and parens == 0:
                    return i + 1
                parens -= 1
                i += 1
            else:
                i += 1
        if in_interpolation:
            raise ParseError(n, "unterminated interpolation")
        return i

    def block_comment(self, i):
        text, n = self.text, len(self.text)
        start, depth = i, 0
        while i < n:
            if text.startswith("/*", i):
                depth += 1
                i += 2
            elif text.startswith("*/", i):
                depth -= 1
                i += 2
                if depth == 0:
                    return i
            else:
                i += 1
        raise ParseError(start, "unterminated block comment")

    def raw_start(self, i):
        j = i
        while j < len(self.text) and self.text[j] == "#":
            j += 1
        return j < len(self.text) and self.text[j] == '"'

    def string(self, i):
        text, n = self.text, len(self.text)
        start = i
        hashes = 0
        while text[i] == "#":
            hashes += 1
            i += 1
        multiline = text.startswith('"""', i)
        i += 3 if multiline else 1
        close = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        literal = Literal()
        while i < n:
            if text.startswith(close, i):
                self.literals.append(literal)
                return i + len(close)
            if not multiline and text[i] == "\n":
                break
            if text.startswith(escape, i):
                at = i
                i += len(escape)
                if i >= n:
                    break
                c = text[i]
                if c == "(":
                    literal.add(BARRIER, at)
                    i = self.code(i + 1, True)
                elif c == "u" and text.startswith("{", i + 1):
                    end = text.find("}", i)
                    digits = text[i + 2 : end] if end > 0 else ""
                    if not re.fullmatch(r"[0-9A-Fa-f]{1,8}", digits):
                        raise ParseError(at, "bad unicode escape")
                    literal.add(chr(int(digits, 16)) if int(digits, 16) <= 0x10FFFF else "�", at)
                    i = end + 1
                elif c == "\n":
                    i += 1
                else:
                    literal.add(SIMPLE_ESCAPES.get(c, c), at)
                    i += 1
            else:
                literal.add(text[i], i)
                i += 1
        raise ParseError(start, "unterminated string literal")


def words_of(literal):
    """Letters and apostrophes make a word, as in CopyRules.allows. Returns [(word, offset)] with barriers as None."""
    words, current, begin = [], [], 0
    for char, offset in zip(literal.chars, literal.offsets):
        if char is not BARRIER and (char.isalpha() or char == "'"):
            if not current:
                begin = offset
            current.append(char)
        else:
            if current:
                words.append(("".join(current).lower().strip("'"), begin))
                current = []
            if char is BARRIER:
                words.append(BARRIER)
    if current:
        words.append(("".join(current).lower().strip("'"), begin))
    return words


def findings(literal, phrases):
    """Yields (offset, rule) for one literal."""
    for char, offset in zip(literal.chars, literal.offsets):
        if char == EN:
            yield offset, "en dash (U+2013) in UI copy"
        elif char == EM:
            yield offset, "em dash (U+2014) in UI copy"
    words = words_of(literal)
    for phrase in phrases:
        size = len(phrase)
        for k in range(len(words) - size + 1):
            window = words[k : k + size]
            if all(w is not BARRIER and w[0] == p for w, p in zip(window, phrase)):
                yield window[0][1], 'banned word "%s" (docs/SPEC.md section 6.6)' % " ".join(phrase)


def is_test_file(path):
    parts = path.split(os.sep)
    return os.path.basename(path).endswith("Tests.swift") or "Tests" in parts[:-1] or "tests" in parts[:-1]


def swift_files(target):
    if os.path.isfile(target):
        return [target]
    found = []
    for folder, dirs, files in os.walk(target):
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in ("Tests", "tests"))
        found += [os.path.join(folder, f) for f in sorted(files) if f.endswith(".swift") and not is_test_file(f)]
    return found


def kind_of(path):
    name = os.path.basename(path)
    if name.endswith(".xcstrings"):
        return "catalog"
    if name.endswith(".plist"):
        return "plist"
    return "swift"


# A format specifier: %@, %lld, %1$@, %.2f and the like. It ends a phrase, as an interpolation does in Swift.
SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA]|%#@[A-Za-z0-9_]+@")


def literal_of(text, line):
    """A Literal for a catalog or plist string. Every offset is the line it was found on."""
    literal = Literal()
    i = 0
    while i < len(text):
        if text.startswith("%%", i):
            literal.add("%", line)
            i += 2
            continue
        match = SPECIFIER.match(text, i)
        if match:
            literal.add(BARRIER, line)
            i = match.end()
            continue
        literal.add(text[i], line)
        i += 1
    return literal


def catalog_strings(text):
    """Every key and every value of a string catalog, as (string, line). Raises ValueError when it is not JSON."""
    lines = {}
    for number, row in enumerate(text.split("\n"), 1):
        for token in re.finditer(r'"((?:[^"\\]|\\.)*)"', row):
            try:
                lines.setdefault(json.loads('"' + token.group(1) + '"'), number)
            except ValueError:
                continue
    data = json.loads(text)
    if not isinstance(data, dict) or not isinstance(data.get("strings", {}), dict):
        raise ValueError("no strings table")
    found = []

    def values(node):
        if isinstance(node, dict):
            unit = node.get("stringUnit")
            if isinstance(unit, dict) and isinstance(unit.get("value"), str):
                found.append(unit["value"])
            for child in node.values():
                values(child)
        elif isinstance(node, list):
            for child in node:
                values(child)

    for key, entry in data.get("strings", {}).items():
        found.append(key)
        values(entry)
    return [(string, lines.get(string, 1)) for string in found]


def plist_strings(text):
    """Every string value of an Info.plist except the exempt keys', as (string, line). Raises ValueError when unreadable."""
    try:
        data = plistlib.loads(text.encode("utf-8"))
    except Exception as error:
        raise ValueError(str(error))
    lines = {}
    for match in re.finditer(r"<string>(.*?)</string>", text, re.S):
        lines.setdefault(html.unescape(match.group(1)), text.count("\n", 0, match.start()) + 1)
    found = []

    def values(node):
        if isinstance(node, dict):
            for key, child in node.items():
                if key not in EXEMPT_PLIST_KEYS:
                    values(child)
        elif isinstance(node, list):
            for child in node:
                values(child)
        elif isinstance(node, str):
            found.append(node)

    values(data)
    return [(string, lines.get(string, 1)) for string in found]


def shown(path):
    absolute = os.path.abspath(path)
    inside = absolute == ROOT or absolute.startswith(ROOT + os.sep)
    return os.path.relpath(absolute, ROOT) if inside else path


def main(argv):
    rules, targets = DEFAULT_RULES, []
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--rules" and args:
            rules = args.pop(0)
        elif arg in ("-h", "--help"):
            sys.stdout.write("Usage: tools/lint_copy.sh [--rules FILE] [PATH ...]\n")
            return 0
        elif arg.startswith("-"):
            sys.stderr.write("Usage: tools/lint_copy.sh [--rules FILE] [PATH ...]\n")
            return 2
        else:
            targets.append(arg)
    phrases = banned_phrases(rules)
    explicit = bool(targets)
    targets = targets or [os.path.join(ROOT, p) for p in DEFAULT_PATHS]
    files = []
    for target in targets:
        if not os.path.exists(target):
            if explicit:
                sys.stderr.write("lint_copy: no such file or folder: %s\n" % target)
                return 2
            continue
        files += swift_files(target)
    count = 0
    for path in files:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        kind = kind_of(path)
        if kind != "swift":
            try:
                strings = (catalog_strings if kind == "catalog" else plist_strings)(text)
            except ValueError as error:
                print("%s:1: cannot parse: %s" % (shown(path), error))
                count += 1
                continue
            hits = sorted({(line, rule) for string, line in strings for _, rule in findings(literal_of(string, line), phrases)})
            for line, rule in hits:
                print("%s:%d: %s" % (shown(path), line, rule))
            count += len(hits)
            continue
        starts = [0] + [m.end() for m in re.finditer("\n", text)]

        def line_of(offset):
            lo, hi = 0, len(starts)
            while lo + 1 < hi:
                mid = (lo + hi) // 2
                if starts[mid] <= offset:
                    lo = mid
                else:
                    hi = mid
            return lo + 1

        scanner = Scanner(text)
        try:
            scanner.code(0, False)
        except ParseError as error:
            print("%s:%d: cannot parse: %s" % (shown(path), line_of(error.offset), error))
            count += 1
            continue
        hits = sorted({(line_of(offset), rule) for lit in scanner.literals for offset, rule in findings(lit, phrases)})
        for line, rule in hits:
            print("%s:%d: %s" % (shown(path), line, rule))
        count += len(hits)
    if count:
        print("lint_copy: %d finding(s)" % count)
        return 1
    print("lint_copy: clean (%d files)" % len(files))
    return 0


sys.exit(main(sys.argv[1:]))
PY
