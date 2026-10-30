/// Row to model mapping for the projection tables. Each reader builds the model's JSON shape from the
/// columns and decodes it, so a row can never produce a value the ledger could not have held.
enum Readers {
    static func entry(_ row: SQLRow) throws(CadenceError) -> Entry {
        var object: [String: JSONValue] = [:]
        for name in [
            "id", "day", "kind", "family", "title", "occurred_at", "duration_s", "quantity", "origin", "source",
            "source_ref", "status", "export",
        ] {
            object[name] = json(row[name])
        }
        object["ticket"] = ticket(row)
        object["links"] = try parsed(row.text("links"), as: "links")
        object["tags"] = try parsed(row.text("tags"), as: "tags")
        object["attrs"] = try parsed(row.text("attrs"), as: "attrs")
        object["backfilled"] = .bool(row.bool("backfilled"))
        object["after_seal"] = .bool(row.bool("after_seal"))
        return try Entry(json: .object(object))
    }

    static func task(_ row: SQLRow) throws(CadenceError) -> PlanTask {
        var object: [String: JSONValue] = [:]
        for name in [
            "id", "day", "position", "title", "estimate_min", "origin", "carried_from", "status", "reason",
            "reason_note", "planned_at", "resolved_at",
        ] {
            object[name] = json(row[name])
        }
        object["ticket"] = ticket(row)
        object["linked_entries"] = try parsed(row.text("linked_entries"), as: "linked_entries")
        return try PlanTask(json: .object(object))
    }

    static func day(_ row: SQLRow) throws(CadenceError) -> Day {
        var object: [String: JSONValue] = [:]
        for name in [
            "date", "tz", "kind", "label", "first_activity", "last_activity", "focus", "note", "sealed_at",
            "seal_event",
        ] {
            object[name] = json(row[name])
        }
        object["on_call"] = .bool(row.bool("on_call"))
        return try Day(json: .object(object))
    }

    private static func json(_ value: SQLValue) -> JSONValue {
        switch value {
        case .null, .blob: .null
        case .int(let i): .int(i)
        case .text(let s): .string(s)
        }
    }

    private static func ticket(_ row: SQLRow) -> JSONValue {
        guard let key = row.text("ticket_key"), let cls = row.text("ticket_class") else { return .null }
        return ["key": .string(key), "class": .string(cls)]
    }

    private static func parsed(_ text: String?, as name: String) throws(CadenceError) -> JSONValue {
        guard let text else { return .null }
        do {
            return try JSONParser.parse(text)
        } catch {
            throw .integrity("stored \(name) is not valid JSON")
        }
    }
}
