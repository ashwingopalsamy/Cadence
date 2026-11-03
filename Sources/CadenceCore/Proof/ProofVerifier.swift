import Foundation

/// What `cadence verify` found in a proof file.
public struct ProofReport: Sendable, Equatable {
    /// Failure messages, without the "FAIL    " prefix, in the order the Python verifier reports them.
    public var fails: [String]
    public var warns: [String]
    /// The exact lines `tools/verify_proof.py` prints, in order, then any `--recompute` notes.
    public var lines: [String]
    public var passed: Bool { fails.isEmpty }
}

/// A Swift port of `tools/verify_proof.py` (docs/SPEC.md section 12.3). That script is the reference: every
/// fail, warn and output line is byte-identical to it, including order.
///
/// Documented divergences, all of which make the Swift side stricter or more explicit:
/// - The input is read with `JSONParser` (cadence-c14n/1), so a file with a float, an integer beyond
///   2^53 - 1, a duplicate key, NaN or a BOM is "not a readable proof" here while Python accepts it.
/// - The text after "the file is not a readable proof:" names the Swift cause, so it differs from Python's
///   exception text. The line shape and the FAIL result are the same.
/// - Where Python would crash with a traceback after verifying (an item with no `origin` or a range with no
///   `tz`), Swift reports the file as not readable.
/// - `instant()` accepts RFC 3339 with an offset only; Python 3.11 also accepts date-only and naive forms.
/// - Python's repr of a non-string `format` is reproduced with sorted dictionary keys, not file order.
/// - Ordering comparisons of values that are not both strings or both numbers raise in Python and here.
public enum ProofVerifier {
    private static let head = ["v", "seq", "id", "at", "actor", "type", "subject", "data_digest", "prev"]
    private static let passText = "PASS: the chain is complete and in order, and every item, seal and witness matches it"

    private struct Unreadable: Error {
        let kind: String
        let message: String
    }

    private typealias Event = [String: JSONValue]

    public static func verify(bytes: [UInt8], recompute: Bool = false) -> ProofReport {
        let value: JSONValue
        do {
            value = try JSONParser.parse(bytes: bytes)
        } catch {
            return unreadable(Unreadable(kind: "ValueError", message: "\(error)"))
        }
        do {
            return try report(value, recompute: recompute)
        } catch let error as Unreadable {
            return unreadable(error)
        } catch {
            return unreadable(Unreadable(kind: "ValueError", message: "\(error)"))
        }
    }

    private static func unreadable(_ error: Unreadable) -> ProofReport {
        let text = "the file is not a readable proof: \(error.kind) \(error.message)"
        return ProofReport(fails: [text], warns: [], lines: ["FAIL    " + text, "RESULT  FAIL"])
    }

    // MARK: Output (main in the Python script)

    private static func report(_ p: JSONValue, recompute: Bool) throws -> ProofReport {
        let outcome = try check(p)
        if let first = outcome.fails.first, first.hasPrefix("unknown format") {
            return ProofReport(fails: outcome.fails, warns: [], lines: ["FAIL    " + first, "RESULT  FAIL"])
        }
        let ev = try iter(get(get(p, "chain"), "events"))
        let days = try iter(get(p, "days"))
        var items: [JSONValue] = []
        for d in days { items += try iter(get(d, "items")) }
        var byOrigin: [String: Int] = [:]
        for it in items {
            guard case .string(let origin) = try get(it, "origin") else { throw Unreadable(kind: "TypeError", message: "origin is not a string") }
            byOrigin[origin, default: 0] += 1
        }
        let range = try get(p, "range")
        var lines: [String] = []
        lines.append("cadence.proof/1  \(str(try get(range, "from"))) .. \(str(try get(range, "to")))  (\(str(try get(range, "tz"))))")
        let headText = ev.isEmpty ? "-" : try prefix16(get(ev[ev.count - 1], "hash"))
        lines.append("chain   \(ev.count) events, head \(headText)")
        let origins = byOrigin.keys.sorted(by: cpLess).map { "\($0) \(byOrigin[$0]!)" }.joined(separator: ", ")
        lines.append("items   \(items.count): \(origins)")
        lines.append("links   \(items.filter { truthy($0["links"]) }.count) items carry a source link to check")
        let witnesses = try iter(p["witnesses"] ?? .array([]))
        lines.append(outcome.fails.contains { $0.contains("witness") } ? "witness MISMATCH" : "witness \(witnesses.count) codes, all found in chain")
        for w in outcome.warns { lines.append("warn    " + w) }
        for f in outcome.fails { lines.append("FAIL    " + f) }
        lines.append("RESULT  " + (outcome.fails.isEmpty ? passText : "FAIL"))
        if recompute, let n = try? hashOnlyInRange(p) {
            lines.append("note    \(n) in-range events are hash-only (private or not accepted); their payloads cannot be recomputed")
        }
        return ProofReport(fails: outcome.fails, warns: outcome.warns, lines: lines)
    }

    /// `--recompute`: events of a day in the range, or of an entry an in-range item cites, that carry no payload.
    private static func hashOnlyInRange(_ p: JSONValue) throws -> Int {
        let lo = try get(get(p, "range"), "from"), hi = try get(get(p, "range"), "to")
        var subjectOf: [JSONValue: JSONValue] = [:]
        let events = try iter(get(get(p, "chain"), "events"))
        for e in events { subjectOf[try get(e, "hash")] = try get(e, "subject") }
        var wanted = Set<JSONValue>()
        for d in try iter(get(p, "days")) {
            let date = try get(d, "date")
            guard try le(lo, date) && le(date, hi), case .string(let s) = date else { continue }
            wanted.insert(.string("day:" + s))
            for it in try iter(get(d, "items")) { if let s = subjectOf[try get(it, "ev")] { wanted.insert(s) } }
        }
        return events.filter { e in
            guard case .object(let o) = e, o["data"] == nil, let s = o["subject"] else { return false }
            return wanted.contains(s)
        }.count
    }

    // MARK: Checks (verify in the Python script)

    private static func check(_ p: JSONValue) throws -> (fails: [String], warns: [String]) {
        var fails: [String] = [], warns: [String] = []
        guard case .object(let root) = p, eq(root["format"] ?? .null, "cadence.proof/1") else {
            let shown: JSONValue = { if case .object(let o) = p { return o["format"] ?? .null } else { return p } }()
            return (["unknown format " + repr(shown)], [])
        }
        let hasher = SHA256Hasher()
        func sha(_ v: JSONValue) throws -> String {
            do { return hasher.sha256Hex(try CanonicalJSON.bytes(v)) } catch { throw Unreadable(kind: "ValueError", message: "\(error)") }
        }
        var body = root
        body["export_digest"] = nil
        if !eq(.string(try sha(.object(body))), root["export_digest"] ?? .null) {
            fails.append("export_digest does not match the file: it was edited after export")
        }
        var prev = String(repeating: "0", count: 64)
        var lastAt = ""
        var byHash: [JSONValue: Event] = [:]
        var bySubject: [JSONValue: [Event]] = [:]
        var byCode: [JSONValue: [Event]] = [:]
        for (n, ev) in try iter(get(get(p, "chain"), "events")).enumerated() {
            guard case .object(let e) = ev else { throw Unreadable(kind: "AttributeError", message: "event is not an object") }
            let tag = "event " + str(e["seq"] ?? .null)
            if !eq(try get(ev, "seq"), .int(Int64(n + 1))) { fails.append(tag + ": sequence gap or reorder") }
            if !eq(try get(ev, "prev"), .string(prev)) { fails.append(tag + ": does not link to the event before it") }
            if let data = e["data"], !eq(.string(try sha(data)), try get(ev, "data_digest")) {
                fails.append(tag + ": payload changed after it was recorded")
            }
            var headObject: [String: JSONValue] = [:]
            for k in head { headObject[k] = try get(ev, k) }
            if !eq(.string(try sha(.object(headObject))), try get(ev, "hash")) { fails.append(tag + ": event hash mismatch") }
            guard case .string(let at) = try get(ev, "at") else { throw Unreadable(kind: "TypeError", message: "'<' not supported for at") }
            if cpLess(at, lastAt) { warns.append(tag + ": recorded time goes backwards (clock change?)") }
            if cpLess(lastAt, at) { lastAt = at }
            guard case .string(let hash) = try get(ev, "hash") else { throw Unreadable(kind: "TypeError", message: "hash is not a string") }
            prev = hash
            let subject = try hashable(get(ev, "subject"))
            byHash[.string(hash)] = e
            bySubject[subject, default: []].append(e)
            byCode[.string(try prefix16(.string(hash))), default: []].append(e)
        }
        let range = try get(p, "range")
        let lo = try get(range, "from"), hi = try get(range, "to")
        var counts: [String: Int] = ["merged_prs": 0, "reviews": 0]
        for d in try iter(get(p, "days")) {
            let date = try get(d, "date")
            let inside = try le(lo, date) ? le(date, hi) : false
            if !inside { fails.append("\(str(date)): day is outside the range") }
            if truthy(d["seal_ev"]) || truthy(d["sealed_at"]) {
                if let s = byHash[try hashable(d["seal_ev"] ?? .null)] {
                    var bad = !eq(s["type"] ?? .null, "day.sealed")
                    if !bad {
                        guard case .string(let ds) = date else { throw Unreadable(kind: "TypeError", message: "can only concatenate str to str") }
                        bad = !eq(s["subject"] ?? .null, .string("day:" + ds))
                    }
                    if bad {
                        fails.append("\(str(date)): seal_ev is not this day's seal")
                    } else if try !sealedAtMatches(d, s) {
                        fails.append("\(str(date)): sealed_at does not match the seal event")
                    }
                } else {
                    fails.append("\(str(date)): references an event that is not in the chain")
                }
            }
            for it in try iter(get(d, "items")) {
                try checkItem(it, date, byHash, bySubject, &fails)
                let kind = try get(it, "kind")
                if eq(kind, "pr.merged"), eq(try get(it, "origin"), "collected") { counts["merged_prs", default: 0] += 1 }
                if eq(kind, "review.given") { counts["reviews", default: 0] += 1 }
            }
        }
        for key in counts.keys.sorted(by: cpLess) {
            // p.get("summary", {}).get(key, {}).get("value", n)
            let n = counts[key]!
            let summary = root["summary"] ?? .object([:])
            guard case .object(let o) = summary else {
                throw Unreadable(kind: "AttributeError", message: "'\(typeName(summary))' object has no attribute 'get'")
            }
            let entry = o[key] ?? .object([:])
            guard case .object(let e) = entry else {
                throw Unreadable(kind: "AttributeError", message: "'\(typeName(entry))' object has no attribute 'get'")
            }
            let value = e["value"] ?? .int(Int64(n))
            if !eq(value, .int(Int64(n))) && !(value == .null && n == 0) {
                fails.append("summary \(key) says \(str(value)), the items show \(n)")
            }
        }
        for w in try iter(root["witnesses"] ?? .array([])) {
            let code = try get(w, "code")
            let u = Array(str(code).utf8)
            let matches = u.count == 16 && u.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
            let hit = matches ? (byCode[try hashable(code)] ?? []) : []
            let date = try get(w, "date")
            var found = false
            for e in hit where eq(e["type"] ?? .null, "witness.checkpoint") {
                guard case .string(let ds) = date else { throw Unreadable(kind: "TypeError", message: "can only concatenate str to str") }
                if eq(e["subject"] ?? .null, .string("day:" + ds)) { found = true; break }
            }
            if !found { fails.append("witness \(str(code)) (\(str(date))) matches no checkpoint for that day") }
        }
        return (fails, warns)
    }

    private static func sealedAtMatches(_ d: JSONValue, _ seal: Event) throws -> Bool {
        guard truthy(d["sealed_at"]) else { return false }
        return try instant(get(d, "sealed_at")) == instant(seal["at"] ?? .null)
    }

    private static func checkItem(
        _ it: JSONValue, _ date: JSONValue, _ byHash: [JSONValue: Event], _ bySubject: [JSONValue: [Event]],
        _ fails: inout [String]
    ) throws {
        let evKey = try hashable(get(it, "ev"))
        guard let e = byHash[evKey] else {
            fails.append("\(str(date)): references an event that is not in the chain")
            return
        }
        let prefix = "\(str(date)): item \(try prefix16(evKey))"
        if !eq(e["type"] ?? .null, "entry.created") || !str(e["subject"] ?? .null).utf8.starts(with: "entry:".utf8) {
            fails.append(prefix + " does not cite an entry.created event")
            return
        }
        let history = bySubject[e["subject"] ?? .null] ?? []
        if !eq(it["last_ev"] ?? .null, history[history.count - 1]["hash"] ?? .null) {
            fails.append(prefix + " last_ev is not the entry's last event")
        }
        if truthy(it["redacted"]) {
            if e["data"] != nil { fails.append(prefix + " is marked redacted but its payload is in the chain") }
            return
        }
        let updates = history.filter { eq($0["type"] ?? .null, "entry.updated") }
        guard let created = e["data"], !updates.contains(where: { $0["data"] == nil }) else {
            fails.append(prefix + " has no payload in the chain to check it against")
            return
        }
        guard case .object(var entry) = created else { throw Unreadable(kind: "TypeError", message: "cannot convert to dict") }
        for u in updates {
            guard case .object(let changes) = try get(u["data"] ?? .null, "changes") else {
                throw Unreadable(kind: "AttributeError", message: "changes has no items")
            }
            for field in changes.keys.sorted(by: cpLess) {
                guard case .array(let change) = changes[field]!, change.count >= 2 else {
                    throw Unreadable(kind: "IndexError", message: "change index out of range")
                }
                entry[field] = change[1]
            }
        }
        let entryValue = JSONValue.object(entry)
        var links: [JSONValue] = []
        for l in try iter(get(entryValue, "links")) { links.append(try get(l, "url")) }
        let shown: [(String, JSONValue)] = [
            ("day", try get(entryValue, "day")), ("family", try get(entryValue, "family")),
            ("kind", try get(entryValue, "kind")), ("links", .array(links)),
            ("origin", try get(entryValue, "origin")), ("ticket", try get(entryValue, "ticket")),
            ("title", try get(entryValue, "title")),
        ]
        for (field, value) in shown {
            let got = field == "day" ? date : (it[field] ?? .null)
            if !eq(got, value) { fails.append(prefix + " \(field) does not match its events") }
        }
    }

    // MARK: Python semantics

    private static func get(_ v: JSONValue, _ key: String) throws -> JSONValue {
        guard case .object(let o) = v else { throw Unreadable(kind: "TypeError", message: "\(typeName(v)) indices must be integers") }
        guard let x = o[key] else { throw Unreadable(kind: "KeyError", message: "'\(key)'") }
        return x
    }

    /// What `for x in v` yields: list elements, dictionary keys or string characters.
    private static func iter(_ v: JSONValue) throws -> [JSONValue] {
        switch v {
        case .array(let a): return a
        case .object(let o): return o.keys.sorted(by: cpLess).map { .string($0) }
        case .string(let s): return s.unicodeScalars.map { .string(String($0)) }
        default: throw Unreadable(kind: "TypeError", message: "'\(typeName(v))' object is not iterable")
        }
    }

    private static func hashable(_ v: JSONValue) throws -> JSONValue {
        switch v {
        case .array, .object: throw Unreadable(kind: "TypeError", message: "unhashable type: '\(typeName(v))'")
        default: return v
        }
    }

    private static func prefix16(_ v: JSONValue) throws -> String {
        guard case .string(let s) = v else { throw Unreadable(kind: "TypeError", message: "'\(typeName(v))' object is not subscriptable") }
        return String(String.UnicodeScalarView(s.unicodeScalars.prefix(16)))
    }

    private static func typeName(_ v: JSONValue) -> String {
        switch v {
        case .null: "NoneType"
        case .bool: "bool"
        case .int: "int"
        case .string: "str"
        case .array: "list"
        case .object: "dict"
        }
    }

    private static func truthy(_ v: JSONValue?) -> Bool {
        switch v ?? .null {
        case .null: false
        case .bool(let b): b
        case .int(let i): i != 0
        case .string(let s): !s.isEmpty
        case .array(let a): !a.isEmpty
        case .object(let o): !o.isEmpty
        }
    }

    private static func number(_ v: JSONValue) -> Int64? {
        switch v {
        case .bool(let b): b ? 1 : 0
        case .int(let i): i
        default: nil
        }
    }

    /// Python `==`: True equals 1 and False equals 0, strings compare by code point.
    private static func eq(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if let x = number(a), let y = number(b) { return x == y }
        switch (a, b) {
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { eq($0, $1) }
        case (.object(let x), .object(let y)):
            return x.count == y.count && x.allSatisfy { k, v in y[k].map { eq(v, $0) } ?? false }
        default: return a == b
        }
    }

    /// Python string order is code point order, which is UTF-8 byte order. Swift's `<` is not.
    private static func cpLess(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    /// Python `a <= b` for two strings or two numbers; anything else raises.
    private static func le(_ a: JSONValue, _ b: JSONValue) throws -> Bool {
        if case .string(let x) = a, case .string(let y) = b { return !cpLess(y, x) }
        if let x = number(a), let y = number(b) { return x <= y }
        throw Unreadable(kind: "TypeError", message: "'<=' not supported between instances of '\(typeName(a))' and '\(typeName(b))'")
    }

    private static func instant(_ v: JSONValue) throws -> Int {
        guard case .string(let s) = v else { throw Unreadable(kind: "AttributeError", message: "'\(typeName(v))' object has no attribute 'replace'") }
        let text = s.replacingOccurrences(of: "Z", with: "+00:00").replacingOccurrences(of: "z", with: "+00:00")
        guard let date = Timestamp.parse(text) else { throw Unreadable(kind: "ValueError", message: "Invalid isoformat string: \(repr(.string(s)))") }
        return Int(date.timeIntervalSince1970)
    }

    /// Python `str(v)`.
    private static func str(_ v: JSONValue) -> String {
        if case .string(let s) = v { return s }
        return repr(v)
    }

    /// Python `repr(v)` (dictionary keys sorted).
    private static func repr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .string(let s): return reprString(s)
        case .array(let a): return "[" + a.map(repr).joined(separator: ", ") + "]"
        case .object(let o): return "{" + o.keys.sorted(by: cpLess).map { reprString($0) + ": " + repr(o[$0]!) }.joined(separator: ", ") + "}"
        }
    }

    private static func reprString(_ s: String) -> String {
        let quote: Unicode.Scalar = s.contains("'") && !s.contains("\"") ? "\"" : "'"
        var out = String(quote)
        for u in s.unicodeScalars {
            if u == "\\" {
                out += "\\\\"
            } else if u == quote {
                out += "\\" + String(quote)
            } else if u == "\n" {
                out += "\\n"
            } else if u == "\r" {
                out += "\\r"
            } else if u == "\t" {
                out += "\\t"
            } else if isPrintable(u) {
                out.unicodeScalars.append(u)
            } else if u.value < 0x100 {
                out += "\\x" + hex(u.value, 2)
            } else if u.value < 0x10000 {
                out += "\\u" + hex(u.value, 4)
            } else {
                out += "\\U" + hex(u.value, 8)
            }
        }
        return out + String(quote)
    }

    private static func isPrintable(_ u: Unicode.Scalar) -> Bool {
        if u == " " { return true }
        switch u.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return false
        default:
            return true
        }
    }

    private static func hex(_ v: UInt32, _ width: Int) -> String {
        let s = String(v, radix: 16)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}
