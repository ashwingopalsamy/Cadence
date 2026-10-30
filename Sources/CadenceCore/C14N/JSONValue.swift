/// A JSON value as Cadence stores and hashes it: no floating point, by design
/// (docs/SPEC.md sections 7.3 and 12.1). Money is micro-dollars and tokens are counts.
public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    /// Canonical JSON only admits integers within ±(2^53 - 1), so every value survives
    /// a round trip through any JSON parser, including the Python verifier's.
    case int(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The largest magnitude canonical JSON accepts: 2^53 - 1.
    public static let maxSafeInteger: Int64 = 9_007_199_254_740_991
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object: [String: JSONValue] = [:]
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool { self == .null }
}

// Equality follows the canonical bytes, not Swift's String equality, which treats canonically
// equivalent strings ("\u{E9}" and "e\u{301}") as equal even though they hash differently in the ledger.
extension JSONValue: Hashable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.int(let a), .int(let b)): a == b
        case (.string(let a), .string(let b)): a.utf8.elementsEqual(b.utf8)
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)):
            a.count == b.count && a.allSatisfy { key, value in b[key].map { $0 == value } ?? false }
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let b): hasher.combine(1); hasher.combine(b)
        case .int(let i): hasher.combine(2); hasher.combine(i)
        case .string(let s): hasher.combine(3); hasher.combine(Array(s.utf8))
        case .array(let a): hasher.combine(4); hasher.combine(a)
        case .object(let o):
            hasher.combine(5)
            for key in o.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                hasher.combine(Array(key.utf8))
                o[key]?.hash(into: &hasher)
            }
        }
    }
}
