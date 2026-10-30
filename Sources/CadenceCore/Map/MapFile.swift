import Foundation

/// A `map/1` file (docs/SPEC.md section 10.5): how to turn one JSON or CSV document into envelope records.
public struct MapFile: Sendable, Equatable {
    public enum Input: String, Sendable { case json, csv }

    public enum Format: String, Sendable {
        case day = "yyyy-MM-dd"
        case iso8601
        case epochSeconds = "epoch-s"
        case epochMilliseconds = "epoch-ms"
    }

    public struct Rule: Sendable, Equatable {
        public var path: MapPath?
        public var const: JSONValue?
        public var defaultValue: JSONValue?
        public var format: Format?
        /// A power of ten.
        public var scale: Int64?
    }

    public var name: String
    public var input: Input
    public var produces: String
    public var records: MapPath
    /// Output field name (dotted for nesting, such as `tokens.in`) to its rule, sorted by name.
    public var fields: [(String, Rule)]
    public var sourceRef: String

    /// A map is a few dozen lines; anything bigger is not one.
    public static let maxBytes = 256 * 1024

    public static func == (a: MapFile, b: MapFile) -> Bool {
        a.name == b.name && a.input == b.input && a.produces == b.produces && a.records == b.records
            && a.sourceRef == b.sourceRef && a.fields.map(\.0) == b.fields.map(\.0) && a.fields.map(\.1) == b.fields.map(\.1)
    }

    /// The fields each record type takes. `attrs.<key>` is open for items.
    static let allowed: [String: Set<String>] = [
        "genai.usage": [
            "day", "tool", "model", "sessions", "requests", "tokens.in", "tokens.out", "tokens.cache_read", "tokens.cache_write",
            "cost_micros", "estimated",
        ],
        "item": ["kind", "title", "occurred_at", "day", "ticket", "duration_s", "quantity"],
        "presence.span": ["start", "end"],
        "leave": ["day", "kind", "label"],
    ]
    static let integers: Set<String> = [
        "sessions", "requests", "tokens.in", "tokens.out", "tokens.cache_read", "tokens.cache_write", "cost_micros", "duration_s",
        "quantity",
    ]
    static let times: Set<String> = ["occurred_at", "start", "end"]
    static let booleans: Set<String> = ["estimated"]

    /// Reads and checks a map. `name` is what reports call it, usually the file name without `.json`.
    public init(bytes: [UInt8], name: String) throws(CadenceError) {
        guard bytes.count <= Self.maxBytes else { throw .validation("map \(name): the file is larger than 256 KB") }
        let value: JSONValue
        do {
            value = try JSONParser.parse(bytes: bytes)
        } catch {
            throw .validation("map \(name): \(EnvelopeReader.describe(error))")
        }
        let r = try RecordReader(
            value, owner: "map \(name)", required: ["cadence", "input", "produces", "fields", "source_ref"],
            optional: ["records", "description"])
        guard try r.string("cadence") == "map/1" else { throw r.fail("cadence", "must be 'map/1'") }
        guard let input = Input(rawValue: try r.string("input")) else { throw r.fail("input", "must be json or csv") }
        let produces = try r.string("produces")
        guard let allowed = Self.allowed[produces] else { throw r.fail("produces", "must be genai.usage, item, presence.span or leave") }
        let records = try MapPath(try r.optionalString("records") ?? "$[*]")
        guard let fieldObject = r.raw("fields").objectValue, !fieldObject.isEmpty else { throw r.fail("fields", "must be a non-empty object") }

        var fields: [(String, Rule)] = []
        for key in fieldObject.keys.sorted() {
            let owner = "map \(name).fields.\(EnvelopeReader.printable(key))"
            let isAttrs = produces == "item" && key.hasPrefix("attrs.") && key.count > 6 && !key.dropFirst(6).contains(".")
            guard allowed.contains(key) || isAttrs else { throw CadenceError.validation("\(owner): is not a field of \(produces)") }
            guard !isAttrs || EnvelopeReader.isValidAttrsKey(String(key.dropFirst(6))) else {
                throw CadenceError.validation("\(owner): an attrs key must be 1 to 64 characters with no control characters")
            }
            let f = try RecordReader(fieldObject[key]!, owner: owner, required: [], optional: ["path", "const", "default", "format", "scale"])
            var rule = Rule()
            if let path = try f.optionalString("path") {
                rule.path = try MapPath(path)
                guard !rule.path!.hasWildcard else { throw f.fail("path", "must select one value, so [*] is not allowed") }
            }
            if let c = f.fields["const"], !c.isNull { rule.const = c }
            guard (rule.path == nil) != (rule.const == nil) else { throw f.fail("path", "needs exactly one of path or const") }
            if let d = f.fields["default"], !d.isNull { rule.defaultValue = d }
            if let text = try f.optionalString("format") {
                guard let format = Format(rawValue: text) else { throw f.fail("format", "must be yyyy-MM-dd, iso8601, epoch-s or epoch-ms") }
                guard key == "day" || Self.times.contains(key) else { throw f.fail("format", "applies to days and times only") }
                if format == .day && key != "day" { throw f.fail("format", "yyyy-MM-dd has no time of day") }
                rule.format = format
            }
            if let scale = try f.optionalInt("scale") {
                guard Self.integers.contains(key) else { throw f.fail("scale", "applies to number fields only") }
                guard scale != 1 else { throw f.fail("scale", "scale must be 10 or more; leave it out for exact values") }
                guard Decimal10.isPowerOfTen(scale) else { throw f.fail("scale", "must be 10, 100 and so on up to 10^12") }
                rule.scale = scale
            }
            // A const or default that the field would refuse is a mistake in the map, not in each record.
            for (label, value) in [("const", rule.const), ("default", rule.defaultValue)] {
                guard let value else { continue }
                do throws(CadenceError) {
                    _ = try MapEngine.convert(value, field: key, rule: rule, zone: TimeZone(secondsFromGMT: 0)!, boundary: .standard)
                } catch {
                    throw f.fail(label, error.message)
                }
            }
            fields.append((key, rule))
        }

        let sourceRef = try r.string("source_ref")
        for placeholder in Self.placeholders(sourceRef) where !fields.contains(where: { $0.0 == placeholder }) {
            throw r.fail("source_ref", "{\(placeholder)} is not one of the fields")
        }
        guard !sourceRef.isEmpty else { throw r.fail("source_ref", "must not be empty") }

        self.name = name
        self.input = input
        self.produces = produces
        self.records = records
        self.fields = fields
        self.sourceRef = sourceRef
    }

    /// A `source_ref` template cut into the text it keeps and the `{field}` names it fills.
    enum Segment: Equatable {
        case text(String)
        case field(String)
    }

    static func segments(_ template: String) -> [Segment] {
        var out: [Segment] = []
        var rest = template[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            if open > rest.startIndex { out.append(.text(String(rest[..<open]))) }
            out.append(.field(String(rest[rest.index(after: open)..<close])))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        return out
    }

    /// The names inside `{...}` in a template, in order.
    static func placeholders(_ template: String) -> [String] {
        segments(template).compactMap { if case .field(let name) = $0 { name } else { nil } }
    }
}

/// Exact decimal arithmetic on number text, so `"0.4213"` dollars scale to 421300 micro-dollars with no float.
enum Decimal10 {
    static func isPowerOfTen(_ n: Int64) -> Bool {
        var v = n
        var k = 0
        while v > 1 && v % 10 == 0 && k < 12 {
            v /= 10
            k += 1
        }
        return v == 1
    }

    /// True for a minus sign followed by a mantissa with a digit that is not zero. Asked of the text, before
    /// `scaled` rounds it, so `-0.0000004` is below zero and `-0.000` is not.
    static func isNegative(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).utf8
        guard t.first == 0x2D else { return false }
        for byte in t.dropFirst() {
            if byte == 0x65 || byte == 0x45 { return false }
            if byte >= 0x31, byte <= 0x39 { return true }
        }
        return false
    }

    /// `text × scale` as an integer. Digits finer than one unit are rounded half away from zero; nil when the text
    /// is not a decimal number or the result does not fit.
    static func scaled(_ text: String, by scale: Int64, exact: Bool = false) -> Int64? {
        let b = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        guard !b.isEmpty, b.count <= 64 else { return nil }
        var i = 0
        var negative = false
        if b[i] == 0x2D || b[i] == 0x2B {
            negative = b[i] == 0x2D
            i += 1
        }
        var digits: [UInt8] = []
        var fraction = 0
        var sawDigit = false
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
            digits.append(b[i] - 0x30)
            sawDigit = true
            i += 1
        }
        if i < b.count, b[i] == 0x2E {
            i += 1
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                digits.append(b[i] - 0x30)
                fraction += 1
                sawDigit = true
                i += 1
            }
        }
        guard sawDigit else { return nil }
        var exponent = 0
        if i < b.count, b[i] == 0x65 || b[i] == 0x45 {
            i += 1
            var expNegative = false
            if i < b.count, b[i] == 0x2D || b[i] == 0x2B {
                expNegative = b[i] == 0x2D
                i += 1
            }
            let start = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39, i - start < 4 {
                exponent = exponent * 10 + Int(b[i] - 0x30)
                i += 1
            }
            guard i > start else { return nil }
            if expNegative { exponent = -exponent }
        }
        guard i == b.count else { return nil }

        var power = 0
        var s = scale
        while s > 1 {
            s /= 10
            power += 1
        }
        let shift = exponent - fraction + power
        var kept = digits
        var roundUp = false
        if shift < 0 {
            let drop = -shift
            if drop >= kept.count {
                roundUp = drop == kept.count && (kept.first ?? 0) >= 5
                if exact && kept.contains(where: { $0 != 0 }) { return nil }
                kept = []
            } else {
                let dropped = kept.suffix(drop)
                if exact && dropped.contains(where: { $0 != 0 }) { return nil }
                roundUp = dropped.first! >= 5
                kept.removeLast(drop)
            }
        } else {
            kept += [UInt8](repeating: 0, count: shift)
        }
        var value: Int64 = 0
        for d in kept {
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(Int64(d))
            guard !o1, !o2 else { return nil }
            value = a
        }
        if roundUp {
            let (a, o) = value.addingReportingOverflow(1)
            guard !o else { return nil }
            value = a
        }
        return negative ? -value : value
    }
}
