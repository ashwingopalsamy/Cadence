import CadenceCore
import Foundation

/// How a tool reaches the store. Each call asks for a journal and drops it afterwards, so a long-running
/// `cadence mcp` never holds the store open between calls and always reads the config as it is now.
public typealias JournalProvider = @Sendable () throws(CadenceError) -> Journal

/// Builders for the JSON Schema subset the server enforces (`JSONSchema`).
enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map { JSONValue.string($0) }) }
        return .object(schema)
    }

    static func string(
        minLength: Int? = nil, maxLength: Int? = nil, format: String? = nil, description: String? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string"]
        if let minLength { schema["minLength"] = .int(Int64(minLength)) }
        if let maxLength { schema["maxLength"] = .int(Int64(maxLength)) }
        if let format { schema["format"] = .string(format) }
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    static func integer(minimum: Int, maximum: Int, description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "integer", "minimum": .int(Int64(minimum)), "maximum": .int(Int64(maximum))]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    static func boolean(description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "boolean"]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    static func date(description: String? = nil) -> JSONValue { string(format: "date", description: description) }

    /// A string that must be one of `options`.
    static func choice(_ options: [String], description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "enum": .array(options.map { JSONValue.string($0) })]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    static func array(of items: JSONValue, maxItems: Int, description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "array", "items": items, "maxItems": .int(Int64(maxItems))]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }
}

/// Reads tool arguments that the schema has already checked, so types are right and only meaning is left.
struct ToolArguments {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) { self.values = values }

    func string(_ key: String) -> String? { values[key]?.stringValue }
    func int(_ key: String) -> Int64? { values[key]?.intValue }
    func bool(_ key: String) -> Bool? { values[key]?.boolValue }
    func array(_ key: String) -> [JSONValue]? { values[key]?.arrayValue }

    func date(_ key: String) throws(CadenceError) -> LocalDate? {
        guard let text = string(key) else { return nil }
        guard let date = LocalDate(text) else { throw .validation("\(key): must be a date as YYYY-MM-DD") }
        return date
    }

    /// A list of enum names such as kinds or families, checked against the enum.
    func values<E: RawRepresentable & CaseIterable>(_ key: String, as _: E.Type) throws(CadenceError) -> [E]
    where E.RawValue == String {
        var out: [E] = []
        for item in array(key) ?? [] {
            guard let text = item.stringValue, let value = E(rawValue: text) else {
                throw .validation("\(key): '\(item.stringValue ?? "")' is not valid; use one of \(E.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            out.append(value)
        }
        return out
    }
}

/// How results are shaped for a model: short, in plain words, and always under the size limit.
enum ToolText {
    /// Room for the text and the structured copy together, under the server's 20,000 characters.
    static let budget = 18_000

    /// The size the server will count for `result`: its whole encoded form in code points, escapes included, with
    /// both the text and the structured copy. The same function decides whether the server has to cut it.
    static func size(of result: MCPToolResult) -> Int {
        MCPServer.size(MCPServer.encodedResult(result))
    }

    /// The largest `n` (at least 1, at most `count`) for which `render(n)` fits the budget.
    static func largestFit(of count: Int, render: (Int) -> MCPToolResult) -> Int {
        guard count > 1 else { return count }
        if size(of: render(count)) <= budget { return count }
        var low = 1
        var high = count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if size(of: render(middle)) <= budget { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The tool parameters are not command-line flags: say `occurred_at`, not `--at`.
    static func forAgent(_ error: CadenceError) -> CadenceError {
        func fix(_ message: String) -> String {
            message.replacingOccurrences(of: "--at:", with: "occurred_at:").replacingOccurrences(of: "--range:", with: "range:")
        }
        switch error {
        case .validation(let message): return .validation(fix(message))
        case .usage(let message): return .usage(fix(message))
        case .notFound(let message): return .notFound(fix(message))
        default: return error
        }
    }

    /// "Thu 29 Oct" for a stored day, or the stored text when it is not a date.
    static func day(_ text: String) -> String {
        LocalDate(text).map(Journal.standUpDate) ?? text
    }

    /// " (ACME-482913)" unless the title already says the key.
    static func ticketSuffix(_ ticket: Ticket?, in title: String) -> String {
        guard let ticket, !title.contains(ticket.key) else { return "" }
        return " (\(ticket.key))"
    }

    static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

    /// Client text on one line: control characters become spaces, runs of spaces collapse, cut to `limit` characters.
    static func oneLine(_ text: String, limit: Int) -> String {
        let spaced = String(String.UnicodeScalarView(text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : $0 }))
        return String(spaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(limit))
    }

    static func entries(_ count: Int) -> String { "\(count) \(count == 1 ? "entry" : "entries")" }

    // MARK: Shapes

    /// The entry as the spec's `log_entry` result shows it.
    static func loggedEntry(_ entry: Entry) -> JSONValue {
        [
            "id": .string(entry.id), "day": .string(entry.day), "kind": .string(entry.kind.rawValue),
            "family": .string(entry.family.rawValue), "title": .string(entry.title), "ticket": entry.ticket?.json ?? .null,
            "origin": .string(entry.origin.rawValue),
        ]
    }

    /// An entry in a list: what a model needs to talk about it, without links, tags or attributes.
    static func listedEntry(_ entry: Entry) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(entry.id), "day": .string(entry.day), "kind": .string(entry.kind.rawValue),
            "family": .string(entry.family.rawValue), "title": .string(entry.title), "origin": .string(entry.origin.rawValue),
            "status": .string(entry.status.rawValue),
        ]
        if entry.occurredAt != nil { object["time"] = .string(Format.clock(entry.occurredAt)) }
        if let ticket = entry.ticket { object["ticket"] = ticket.json }
        if entry.quantity > 1 { object["quantity"] = .int(entry.quantity) }
        if let seconds = entry.durationS { object["duration_min"] = .int(seconds / 60) }
        return .object(object)
    }

    static func listedTask(_ task: PlanTask) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(task.id), "position": .int(task.position), "title": .string(task.title),
            "status": .string(task.status.rawValue), "origin": .string(task.origin.rawValue),
        ]
        if let ticket = task.ticket { object["ticket"] = ticket.json }
        if let estimate = task.estimateMin { object["estimate_min"] = .int(estimate) }
        if let reason = task.reason { object["reason"] = .string(reason) }
        return .object(object)
    }
}
