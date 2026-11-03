extension Journal {
    /// 1 when a plan task was added after the current seal of its day, else 0 (docs/SPEC.md section 3, "After the
    /// seal"). It compares two places in the ledger: the task's `plan.added` (`created_seq`) and the event that is the
    /// day's seal (`days.seal_event` is its hash, and the seal after the last reopening stands). Nothing is stored, so
    /// the answer cannot differ between a live store, a rebuilt one and one made before this rule, and no writer can
    /// forget it. A day with no seal has no boundary, so nothing on it is after the seal: that is also why reopening a
    /// day clears the mark on its tasks without touching them.
    static let taskAfterSealSQL = """
        (plan_tasks.created_seq > COALESCE(
            (SELECT e.seq FROM days AS d JOIN events AS e ON e.hash = d.seal_event WHERE d.date = plan_tasks.day),
            9223372036854775807))
        """

    /// The columns of a plan task read through `Readers.task`: the stored row plus the derived `after_seal`.
    static let taskColumns = "plan_tasks.*, \(taskAfterSealSQL) AS after_seal"
}

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
        var task = try PlanTask(json: .object(object))
        // Only a query that selects `Journal.taskColumns` has the column; any other row reads as not after the seal.
        task.afterSeal = row.bool("after_seal")
        return task
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
