import CadenceCore

/// The JSON Schema subset tool inputs use: `type`, `properties`, `required`, `additionalProperties: false`,
/// `enum`, `minLength`, `maxLength`, `minimum`, `maximum`, `items`, `maxItems` and `format` (date, uri). A schema
/// that uses anything else, puts a keyword on a type it does not apply to, or gives a keyword a value of the wrong
/// shape is refused when a tool is registered, so a schema never promises a check that does not happen.
public enum JSONSchema {
    static let common: Set<String> = ["type", "enum", "description"]
    static let byType: [String: Set<String>] = [
        "object": ["properties", "required", "additionalProperties"],
        "string": ["minLength", "maxLength", "format"],
        "integer": ["minimum", "maximum"],
        "boolean": [],
        "array": ["items", "maxItems"],
    ]

    /// Throws when `schema` uses anything this validator does not enforce.
    public static func check(_ schema: JSONValue, at path: String = "inputSchema") throws(CadenceError) {
        guard let object = schema.objectValue else { throw .validation("\(path): must be an object") }
        let type = object["type"]
        if let type, type.stringValue.flatMap({ byType[$0] }) == nil {
            throw .validation("\(path).type: must be object, string, integer, boolean or array")
        }
        // Without a type only `enum` can be checked, so nothing else may appear.
        let allowed = common.union(type?.stringValue.flatMap { byType[$0] } ?? [])
        for key in object.keys.sorted() where !allowed.contains(key) {
            throw .validation(type == nil ? "\(path).\(key): needs a type" : "\(path).\(key): is not supported here")
        }
        if let options = object["enum"] {
            guard let list = options.arrayValue, !list.isEmpty else { throw .validation("\(path).enum: must be a non-empty list") }
            for option in list where violation(of: .object(object.filter { $0.key != "enum" }), by: option) != nil {
                throw .validation("\(path).enum: every option must fit the type")
            }
        }
        if let description = object["description"], description.stringValue == nil {
            throw .validation("\(path).description: must be text")
        }
        for key in ["minLength", "maxLength", "minimum", "maximum", "maxItems"] {
            if let bound = object[key], bound.intValue == nil { throw .validation("\(path).\(key): must be a whole number") }
        }
        if let format = object["format"], !["date", "uri"].contains(format.stringValue ?? "") {
            throw .validation("\(path).format: only date and uri are supported")
        }
        if let extra = object["additionalProperties"], extra != .bool(false) {
            throw .validation("\(path).additionalProperties: only false is supported")
        }
        let properties: [String: JSONValue]
        if let given = object["properties"] {
            guard let map = given.objectValue else { throw .validation("\(path).properties: must be an object") }
            properties = map
        } else {
            properties = [:]
        }
        if let required = object["required"] {
            guard let names = required.arrayValue?.compactMap(\.stringValue), names.count == required.arrayValue?.count else {
                throw .validation("\(path).required: must be a list of names")
            }
            // A required name with no property could never be sent past additionalProperties: false.
            for name in names where properties[name] == nil {
                throw .validation("\(path).required: \(name) is not a property")
            }
        }
        for (name, sub) in properties.sorted(by: { $0.key < $1.key }) {
            try check(sub, at: "\(path).properties.\(name)")
        }
        if let items = object["items"] { try check(items, at: "\(path).items") }
    }

    /// The first way `value` breaks `schema`, as "field: what is wrong", or nil when it fits.
    public static func violation(of schema: JSONValue, by value: JSONValue, at path: String = "") -> String? {
        guard let s = schema.objectValue else { return nil }
        let name = path.isEmpty ? "arguments" : path
        if let options = s["enum"]?.arrayValue, !options.contains(value) {
            let shown = options.map { $0.stringValue ?? (try? CanonicalJSON.string($0)) ?? "?" }
            return "\(name): must be one of \(shown.joined(separator: ", "))"
        }
        switch s["type"]?.stringValue {
        case "object":
            guard let object = value.objectValue else { return "\(name): must be an object" }
            let properties = s["properties"]?.objectValue ?? [:]
            for key in (s["required"]?.arrayValue ?? []).compactMap(\.stringValue) where object[key] == nil {
                return "\(path.isEmpty ? key : "\(path).\(key)"): is required"
            }
            if s["additionalProperties"] == .bool(false) {
                for key in object.keys.sorted() where properties[key] == nil {
                    return "\(path.isEmpty ? key : "\(path).\(key)"): is not a known argument"
                }
            }
            for key in object.keys.sorted() {
                if let sub = properties[key], let problem = violation(of: sub, by: object[key]!, at: path.isEmpty ? key : "\(path).\(key)") {
                    return problem
                }
            }
        case "string":
            guard let text = value.stringValue else { return "\(name): must be a string" }
            // Lengths count code points, as JSON Schema does, so combining marks cannot stretch a limit.
            let length = text.unicodeScalars.count
            if let min = s["minLength"]?.intValue, length < min { return "\(name): must be at least \(min) characters" }
            if let max = s["maxLength"]?.intValue, length > max { return "\(name): must be at most \(max) characters" }
            if s["format"]?.stringValue == "date", LocalDate(text) == nil { return "\(name): must be a date as YYYY-MM-DD" }
            if s["format"]?.stringValue == "uri", !isWebURL(text) { return "\(name): must be an http or https URL" }
        case "integer":
            guard let n = value.intValue else { return "\(name): must be a whole number" }
            if let min = s["minimum"]?.intValue, n < min { return "\(name): must be at least \(min)" }
            if let max = s["maximum"]?.intValue, n > max { return "\(name): must be at most \(max)" }
        case "boolean":
            guard value.boolValue != nil else { return "\(name): must be true or false" }
        case "array":
            guard let items = value.arrayValue else { return "\(name): must be a list" }
            if let max = s["maxItems"]?.intValue, items.count > max { return "\(name): at most \(max) items" }
            if let sub = s["items"] {
                for (i, item) in items.enumerated() {
                    if let problem = violation(of: sub, by: item, at: "\(name)[\(i)]") { return problem }
                }
            }
        default:
            break
        }
        return nil
    }

    /// `http://` or `https://` followed by a host.
    static func isWebURL(_ text: String) -> Bool {
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            let rest = text.dropFirst(scheme.count)
            let host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            return !host.isEmpty && !host.contains(where: { $0.isWhitespace })
        }
        return false
    }
}
