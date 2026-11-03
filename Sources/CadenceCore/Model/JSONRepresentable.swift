/// A domain value with a fixed JSON shape (docs/SPEC.md sections 7.2 and 7.3).
/// Encoding is total. Decoding reports the offending field in a `.validation` error.
public protocol JSONRepresentable {
    var json: JSONValue { get }
    init(json: JSONValue) throws(CadenceError)
}

/// Field-by-field reader that produces uniform validation errors.
struct JSONFields {
    let object: [String: JSONValue]
    let owner: String

    init(_ json: JSONValue, owner: String) throws(CadenceError) {
        guard case .object(let object) = json else {
            throw .validation("\(owner): expected an object")
        }
        self.object = object
        self.owner = owner
    }

    private func fail(_ key: String, _ what: String) -> CadenceError {
        .validation("\(owner).\(key): \(what)")
    }

    /// The value for `key`, or nil when missing or null.
    func value(_ key: String) -> JSONValue? {
        guard let v = object[key], v != .null else { return nil }
        return v
    }

    func string(_ key: String) throws(CadenceError) -> String {
        guard let v = value(key) else { throw fail(key, "is required") }
        guard let s = v.stringValue else { throw fail(key, "must be a string") }
        return s
    }

    func optionalString(_ key: String) throws(CadenceError) -> String? {
        guard let v = value(key) else { return nil }
        guard let s = v.stringValue else { throw fail(key, "must be a string") }
        return s
    }

    func int(_ key: String) throws(CadenceError) -> Int64 {
        guard let v = value(key) else { throw fail(key, "is required") }
        guard let i = v.intValue else { throw fail(key, "must be an integer") }
        return i
    }

    func int(_ key: String, default fallback: Int64) throws(CadenceError) -> Int64 {
        guard let v = value(key) else { return fallback }
        guard let i = v.intValue else { throw fail(key, "must be an integer") }
        return i
    }

    func optionalInt(_ key: String) throws(CadenceError) -> Int64? {
        guard let v = value(key) else { return nil }
        guard let i = v.intValue else { throw fail(key, "must be an integer") }
        return i
    }

    func bool(_ key: String, default fallback: Bool) throws(CadenceError) -> Bool {
        guard let v = value(key) else { return fallback }
        guard let b = v.boolValue else { throw fail(key, "must be a boolean") }
        return b
    }

    func strings(_ key: String) throws(CadenceError) -> [String] {
        guard let v = value(key) else { return [] }
        guard let items = v.arrayValue else { throw fail(key, "must be an array of strings") }
        var out: [String] = []
        for item in items {
            guard let s = item.stringValue else { throw fail(key, "must be an array of strings") }
            out.append(s)
        }
        return out
    }

    func object(_ key: String) throws(CadenceError) -> [String: JSONValue] {
        guard let v = value(key) else { return [:] }
        guard let o = v.objectValue else { throw fail(key, "must be an object") }
        return o
    }

    func array(_ key: String) throws(CadenceError) -> [JSONValue] {
        guard let v = value(key) else { return [] }
        guard let a = v.arrayValue else { throw fail(key, "must be an array") }
        return a
    }

    func enumValue<E: RawRepresentable>(_ key: String, as _: E.Type = E.self, default fallback: E? = nil)
        throws(CadenceError) -> E where E.RawValue == String
    {
        guard let v = value(key) else {
            if let fallback { return fallback }
            throw fail(key, "is required")
        }
        guard let s = v.stringValue else { throw fail(key, "must be a string") }
        guard let e = E(rawValue: s) else { throw fail(key, "unknown value '\(s)'") }
        return e
    }
}

extension Optional where Wrapped == String {
    var jsonValue: JSONValue { self.map { .string($0) } ?? .null }
}

extension Optional where Wrapped == Int64 {
    var jsonValue: JSONValue { self.map { .int($0) } ?? .null }
}
