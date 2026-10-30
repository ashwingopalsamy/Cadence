import CadenceCore

/// The JSON Schema subset tool inputs use: `type`, `properties`, `required`, `additionalProperties: false`,
/// `enum`, `minLength`, `maxLength`, `minimum`, `maximum`, `items`, `maxItems` and `format: date`. A schema
/// keyword outside this list is refused when a tool is registered, so a schema never promises a check that
/// does not happen.
public enum JSONSchema {
    static let keywords: Set<String> = [
        "type", "properties", "required", "additionalProperties", "enum", "minLength", "maxLength", "minimum", "maximum",
        "items", "maxItems", "format", "description",
    ]

    /// Throws when `schema` uses anything this validator does not enforce.
    public static func check(_ schema: JSONValue, at path: String = "inputSchema") throws(CadenceError) {
        guard let object = schema.objectValue else { throw .validation("\(path): must be an object") }
        for key in object.keys.sorted() where !keywords.contains(key) {
            throw .validation("\(path).\(key): is not supported")
        }
        if let type = object["type"], !["object", "string", "integer", "boolean", "array"].contains(type.stringValue ?? "") {
            throw .validation("\(path).type: must be object, string, integer, boolean or array")
        }
        if let format = object["format"]?.stringValue, !["date", "uri"].contains(format) {
            throw .validation("\(path).format: only date and uri are supported")
        }
        if let extra = object["additionalProperties"], extra != .bool(false) {
            throw .validation("\(path).additionalProperties: only false is supported")
        }
        for (name, sub) in (object["properties"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            try check(sub, at: "\(path).properties.\(name)")
        }
        if let items = object["items"] { try check(items, at: "\(path).items") }
    }

    /// The first way `value` breaks `schema`, as "field: what is wrong", or nil when it fits.
    public static func violation(of schema: JSONValue, by value: JSONValue, at path: String = "") -> String? {
        guard let s = schema.objectValue else { return nil }
        let name = path.isEmpty ? "arguments" : path
        if let options = s["enum"]?.arrayValue, !options.contains(value) {
            return "\(name): must be one of \(options.compactMap(\.stringValue).joined(separator: ", "))"
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
            if let min = s["minLength"]?.intValue, text.count < min { return "\(name): must be at least \(min) characters" }
            if let max = s["maxLength"]?.intValue, text.count > max { return "\(name): must be at most \(max) characters" }
            if s["format"]?.stringValue == "date", LocalDate(text) == nil { return "\(name): must be a date as YYYY-MM-DD" }
            if s["format"]?.stringValue == "uri", !(text.hasPrefix("https://") || text.hasPrefix("http://")) {
                return "\(name): must be an http or https URL"
            }
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
}
