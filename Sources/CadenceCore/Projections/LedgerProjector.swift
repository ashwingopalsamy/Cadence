/// The projector for every event type in docs/SPEC.md section 7.3.
///
/// Projections are a pure function of the event sequence: every value comes from an event's
/// payload, its `seq`, its `at` or its `hash`, never from the clock or config. That is what lets
/// `cadence rebuild` reproduce the tables byte for byte. Two derived rules:
///
/// - A day row is created the first time any event refers to the day. Its zone is the zone the
///   first event that carries one gives it (day marks, spans, declarations, notes, commits, seals).
///   Until then it holds the profile zone from `ledger.genesis`, marked provisional in meta, so a
///   plan or backfill written before a travel day starts does not fix the wrong zone. Once set from
///   an event the zone never changes, so later travel never rewrites history.
/// - `days.kind` is `workday` until a `day.declared` says otherwise. Weekends are derived at read
///   time from the configured workdays, so changing config never needs a rebuild.
///
/// Unknown event types are ignored, so events a newer binary adds within the same schema version
/// do not stop a rebuild. A newer schema version is refused outright (see `Migrator`).
///
/// Every reference is checked: an update, resolution, commit or status change that names a task or
/// entry that does not exist, or that would leave a row the creating event's rules would refuse,
/// fails the append.
public struct LedgerProjector: Projector {
    public init() {}

    public func reset(in db: SQLiteDatabase) throws(CadenceError) {
        try sql(db) {
            for table in Schema.projectionTables { try db.run("DELETE FROM \(table)") }
            try db.run("DELETE FROM meta WHERE key LIKE 'projection.%'")
        }
    }

    public func apply(_ event: Event, in db: SQLiteDatabase) throws(CadenceError) {
        guard EventPayload.allTypes.contains(event.type) else { return }
        let payload: EventPayload
        do {
            payload = try EventPayload(type: event.type, data: event.data)
        } catch {
            throw .integrity("event \(event.seq) (\(event.type)) has an invalid payload: \(error.message)")
        }
        try sql(db) { try project(payload, event: event, db: db) }
    }

    // MARK: - Per type

    private func project(_ payload: EventPayload, event: Event, db: SQLiteDatabase) throws {
        let seq = SQLValue.int(event.seq)
        switch payload {
        case .genesis(let genesis):
            let zone = genesis.profile["timezone"]?.stringValue ?? "UTC"
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('projection.profile_tz', ?)", [.text(zone)])

        case .dayStarted(let mark):
            try ensureDay(mark.day, tz: mark.tz, seq: event.seq, db: db)
            try widenActivity(day: mark.day, first: mark.at, last: nil, db: db)
            try touchDay(mark.day, seq: seq, db: db)

        case .dayEnded(let mark):
            try ensureDay(mark.day, tz: mark.tz, seq: event.seq, db: db)
            try widenActivity(day: mark.day, first: nil, last: mark.at, db: db)
            try touchDay(mark.day, seq: seq, db: db)

        case .presenceSpan(let span):
            try ensureDay(span.day, tz: span.tz, seq: event.seq, db: db)
            try db.run(
                "INSERT INTO presence_spans (id, day, start_at, end_at, source) VALUES (?, ?, ?, ?, ?)",
                [seq, .text(span.day), .text(span.start), .text(span.end), .text(span.source.rawValue)])
            try widenActivity(day: span.day, first: span.start, last: span.end, db: db)
            try touchDay(span.day, seq: seq, db: db)

        case .dayDeclared(let declared):
            try ensureDay(declared.day, tz: declared.tz, seq: event.seq, db: db)
            try db.run(
                "UPDATE days SET kind = ?, label = ? WHERE date = ?",
                [.text(declared.kind.rawValue), SQLValue(declared.label), .text(declared.day)])
            try touchDay(declared.day, seq: seq, db: db)

        case .dayNoted(let noted):
            try ensureDay(noted.day, tz: noted.tz, seq: event.seq, db: db)
            if let focus = noted.focus {
                try db.run("UPDATE days SET focus = ? WHERE date = ?", [.text(focus), .text(noted.day)])
            }
            if let note = noted.note {
                try db.run("UPDATE days SET note = ? WHERE date = ?", [.text(note), .text(noted.day)])
            }
            if let onCall = noted.onCall {
                try db.run("UPDATE days SET on_call = ? WHERE date = ?", [SQLValue(onCall), .text(noted.day)])
            }
            try touchDay(noted.day, seq: seq, db: db)

        case .planAdded(let task):
            try ensureDay(task.day, tz: nil, seq: event.seq, db: db)
            try db.run(
                """
                INSERT INTO plan_tasks (id, day, position, title, ticket_key, ticket_class, estimate_min, origin,
                  carried_from, status, reason, reason_note, linked_entries, planned_at, resolved_at, created_seq, updated_seq)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(task.id), .text(task.day), .int(task.position), .text(task.title),
                 SQLValue(task.ticket?.key), SQLValue(task.ticket?.class.rawValue), SQLValue(task.estimateMin),
                 .text(task.origin.rawValue), SQLValue(task.carriedFrom), .text(task.status.rawValue),
                 SQLValue(task.reason), SQLValue(task.reasonNote), .text(try canonical(task.linkedEntries.map(JSONValue.string))),
                 .text(task.plannedAt), SQLValue(task.resolvedAt), seq, seq])
            try touchDay(task.day, seq: seq, db: db)

        case .planUpdated(let changes):
            let id = try subjectID(event, prefix: "task:")
            guard var object = try taskJSON(id, db: db)?.objectValue else {
                throw CadenceError.integrity("event \(event.seq) (plan.updated) refers to an unknown plan task \(id)")
            }
            for (field, change) in changes.fields.sorted(by: { $0.key < $1.key }) {
                guard ["title", "ticket", "estimate_min", "position"].contains(field) else {
                    throw CadenceError.integrity("event \(event.seq): plan.updated cannot change \(field)")
                }
                object[field] = change.new
            }
            let task: PlanTask
            do {
                task = try EventPayload.validatedUpdatedTask(.object(object))
            } catch {
                throw CadenceError.integrity("event \(event.seq): \(error.message)")
            }
            try db.run(
                "UPDATE plan_tasks SET title = ?, ticket_key = ?, ticket_class = ?, estimate_min = ?, position = ?, updated_seq = ? WHERE id = ?",
                [.text(task.title), SQLValue(task.ticket?.key), SQLValue(task.ticket?.class.rawValue),
                 SQLValue(task.estimateMin), .int(task.position), seq, .text(id)])

        case .planResolved(let resolved):
            let id = try subjectID(event, prefix: "task:")
            for entryID in resolved.links where try db.first("SELECT 1 AS x FROM entries WHERE id = ?", [.text(entryID)]) == nil {
                throw CadenceError.integrity("event \(event.seq) (plan.resolved) links an unknown entry \(entryID)")
            }
            let resolvedAt: SQLValue = resolved.status.isResolved || resolved.status == .moved ? .text(event.at) : .null
            try db.run(
                """
                UPDATE plan_tasks SET status = ?, reason = ?, reason_note = ?, linked_entries = ?, resolved_at = ?,
                  updated_seq = ? WHERE id = ?
                """,
                [.text(resolved.status.rawValue), SQLValue(resolved.reason), SQLValue(resolved.reasonNote),
                 .text(try canonical(resolved.links.map(JSONValue.string))), resolvedAt, seq, .text(id)])
            try requireChanged(db, "plan task \(id)", event: event)

        case .planCommitted(let committed):
            try ensureDay(committed.day, tz: committed.tz, seq: event.seq, db: db)
            if let focus = committed.focus {
                try db.run("UPDATE days SET focus = ? WHERE date = ?", [.text(focus), .text(committed.day)])
            }
            // Listed tasks take positions 1...n in order; the day's other tasks follow in their old order,
            // so positions never collide.
            guard Set(committed.tasks).count == committed.tasks.count else {
                throw CadenceError.integrity("event \(event.seq) (plan.committed) lists a task twice")
            }
            for taskID in committed.tasks {
                guard let row = try db.first("SELECT day FROM plan_tasks WHERE id = ?", [.text(taskID)]) else {
                    throw CadenceError.integrity("event \(event.seq) (plan.committed) refers to an unknown plan task \(taskID)")
                }
                guard row.text("day") == committed.day else {
                    throw CadenceError.integrity("event \(event.seq) (plan.committed) lists task \(taskID) from another day")
                }
            }
            let listed = Set(committed.tasks)
            let others = try db.query(
                "SELECT id FROM plan_tasks WHERE day = ? ORDER BY position, created_seq", [.text(committed.day)]
            ).compactMap { $0.text("id") }.filter { !listed.contains($0) }
            for (index, taskID) in (committed.tasks + others).enumerated() {
                try db.run(
                    "UPDATE plan_tasks SET position = ?, updated_seq = ? WHERE id = ?",
                    [.int(Int64(index + 1)), seq, .text(taskID)])
            }
            try touchDay(committed.day, seq: seq, db: db)

        case .entryCreated(let entry):
            try ensureDay(entry.day, tz: nil, seq: event.seq, db: db)
            try db.run(
                """
                INSERT INTO entries (id, day, kind, family, title, occurred_at, duration_s, quantity, ticket_key, ticket_class,
                  links, tags, attrs, origin, source, source_ref, status, backfilled, after_seal, export, created_seq, updated_seq)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(entry.id), .text(entry.day), .text(entry.kind.rawValue), .text(entry.family.rawValue),
                 .text(entry.title), SQLValue(entry.occurredAt), SQLValue(entry.durationS), .int(entry.quantity),
                 SQLValue(entry.ticket?.key), SQLValue(entry.ticket?.class.rawValue),
                 .text(try canonical(.array(entry.links.map(\.json)))), .text(try canonical(.array(entry.tags.map(JSONValue.string)))),
                 .text(try canonical(.object(entry.attrs))), .text(entry.origin.rawValue), SQLValue(entry.source),
                 SQLValue(entry.sourceRef), .text(entry.status.rawValue), SQLValue(entry.backfilled),
                 SQLValue(entry.afterSeal), .text(entry.export.rawValue), seq, seq])
            try touchDay(entry.day, seq: seq, db: db)

        case .entryUpdated(let changes):
            let id = try subjectID(event, prefix: "entry:")
            guard var object = try entryJSON(id, db: db)?.objectValue else {
                throw CadenceError.integrity("event \(event.seq) (entry.updated) refers to an unknown entry \(id)")
            }
            for (field, change) in changes.fields.sorted(by: { $0.key < $1.key }) {
                guard Self.editableEntryFields.contains(field) else {
                    throw CadenceError.integrity("event \(event.seq): entry.updated cannot change \(field)")
                }
                object[field] = change.new
            }
            let entry: Entry
            do {
                entry = try EventPayload.validatedEntry(.object(object), owner: "entry.updated")
            } catch {
                throw CadenceError.integrity("event \(event.seq): \(error.message)")
            }
            try ensureDay(entry.day, tz: nil, seq: event.seq, db: db)
            try db.run(
                """
                UPDATE entries SET day = ?, kind = ?, family = ?, title = ?, occurred_at = ?, duration_s = ?, quantity = ?,
                  ticket_key = ?, ticket_class = ?, links = ?, tags = ?, attrs = ?, backfilled = ?, after_seal = ?,
                  export = ?, updated_seq = ? WHERE id = ?
                """,
                [.text(entry.day), .text(entry.kind.rawValue), .text(entry.family.rawValue), .text(entry.title),
                 SQLValue(entry.occurredAt), SQLValue(entry.durationS), .int(entry.quantity),
                 SQLValue(entry.ticket?.key), SQLValue(entry.ticket?.class.rawValue),
                 .text(try canonical(.array(entry.links.map(\.json)))), .text(try canonical(.array(entry.tags.map(JSONValue.string)))),
                 .text(try canonical(.object(entry.attrs))), SQLValue(entry.backfilled), SQLValue(entry.afterSeal),
                 .text(entry.export.rawValue), seq, .text(id)])

        case .entryStatus(let change):
            let id = try subjectID(event, prefix: "entry:")
            guard let current = try db.first("SELECT status FROM entries WHERE id = ?", [.text(id)])?.text("status") else {
                throw CadenceError.integrity("event \(event.seq) (entry.status) refers to an unknown entry \(id)")
            }
            guard current == change.from.rawValue else {
                throw CadenceError.integrity("event \(event.seq) (entry.status) says from \(change.from.rawValue), but the entry is \(current)")
            }
            try db.run("UPDATE entries SET status = ?, updated_seq = ? WHERE id = ?", [.text(change.to.rawValue), seq, .text(id)])

        case .daySealed(let sealed):
            guard sealed.head == event.prev else {
                throw CadenceError.integrity("event \(event.seq) (day.sealed) head is not the event before the seal")
            }
            try ensureDay(sealed.day, tz: sealed.tz, seq: event.seq, db: db)
            try db.run(
                // The first seal stands: sealing again later must not undo a seal that counted.
                "UPDATE days SET sealed_at = ?, seal_event = ? WHERE date = ? AND sealed_at IS NULL",
                [.text(event.at), .text(event.hash), .text(sealed.day)])
            try touchDay(sealed.day, seq: seq, db: db)

        case .genaiSession(let session):
            // Start and end can arrive as separate events; later non-null values win, nulls keep what is there.
            try db.run(
                """
                INSERT INTO genai_sessions (session_id, tool, day, started_at, ended_at, end_reason, project_alias, models, turns)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                  tool = excluded.tool, day = excluded.day,
                  started_at = COALESCE(genai_sessions.started_at, excluded.started_at),
                  ended_at = COALESCE(excluded.ended_at, genai_sessions.ended_at),
                  end_reason = COALESCE(excluded.end_reason, genai_sessions.end_reason),
                  project_alias = COALESCE(excluded.project_alias, genai_sessions.project_alias),
                  models = CASE WHEN excluded.models = '[]' THEN genai_sessions.models ELSE excluded.models END,
                  turns = COALESCE(excluded.turns, genai_sessions.turns)
                """,
                [.text(session.sessionId), .text(session.tool), .text(session.day), .text(session.startedAt),
                 SQLValue(session.endedAt), SQLValue(session.endReason), SQLValue(session.projectAlias),
                 .text(try canonical(.array(session.models.map(JSONValue.string)))), SQLValue(session.turns)])

        case .genaiUsage(let usage):
            try db.run(
                """
                INSERT OR REPLACE INTO genai_usage (day, tool, model, source, sessions, requests, tokens_in, tokens_out,
                  tokens_cache_read, tokens_cache_write, cost_micros) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(usage.day), .text(usage.tool), .text(usage.model), .text(usage.source), .int(usage.sessions),
                 SQLValue(usage.requests), SQLValue(usage.tokens.input), SQLValue(usage.tokens.output),
                 SQLValue(usage.tokens.cacheRead), SQLValue(usage.tokens.cacheWrite), SQLValue(usage.costMicros)])

        case .witness, .ingestRun, .configClassifier:
            break  // read straight from the ledger
        }
    }

    // MARK: - Helpers

    private func ensureDay(_ date: String, tz: String?, seq: Int64, db: SQLiteDatabase) throws {
        let provisional = "projection.provisional_tz." + date
        let exists = try db.first("SELECT 1 AS x FROM days WHERE date = ?", [.text(date)]) != nil
        if exists {
            // The first event that carries a zone replaces a provisional profile zone.
            if let tz, try db.first("SELECT 1 AS x FROM meta WHERE key = ?", [.text(provisional)]) != nil {
                try db.run("UPDATE days SET tz = ? WHERE date = ?", [.text(tz), .text(date)])
                try db.run("DELETE FROM meta WHERE key = ?", [.text(provisional)])
            }
            return
        }
        if let tz {
            try db.run("INSERT INTO days (date, tz, updated_seq) VALUES (?, ?, ?)", [.text(date), .text(tz), .int(seq)])
        } else {
            let zone = try db.first("SELECT value FROM meta WHERE key = 'projection.profile_tz'")?.text("value") ?? "UTC"
            try db.run("INSERT INTO days (date, tz, updated_seq) VALUES (?, ?, ?)", [.text(date), .text(zone), .int(seq)])
            try db.run("INSERT INTO meta (key, value) VALUES (?, '1')", [.text(provisional)])
        }
    }

    static let editableEntryFields: Set<String> = [
        "title", "kind", "family", "export", "occurred_at", "duration_s", "quantity", "ticket", "links", "tags", "attrs",
        "day", "backfilled", "after_seal",
    ]

    /// The stored entry as the JSON `entry.created` carries, so an update can be checked by the same rules.
    private func entryJSON(_ id: String, db: SQLiteDatabase) throws -> JSONValue? {
        guard let r = try db.first("SELECT * FROM entries WHERE id = ?", [.text(id)]) else { return nil }
        return [
            "id": .string(id), "day": .string(r.text("day") ?? ""), "kind": .string(r.text("kind") ?? ""),
            "family": .string(r.text("family") ?? ""), "title": .string(r.text("title") ?? ""),
            "occurred_at": r.text("occurred_at").map(JSONValue.string) ?? .null,
            "duration_s": r.int("duration_s").map(JSONValue.int) ?? .null, "quantity": .int(r.int("quantity") ?? 1),
            "ticket": Self.ticketJSON(r), "links": try stored(r.text("links")), "tags": try stored(r.text("tags")),
            "attrs": try stored(r.text("attrs")), "origin": .string(r.text("origin") ?? ""),
            "source": r.text("source").map(JSONValue.string) ?? .null,
            "source_ref": r.text("source_ref").map(JSONValue.string) ?? .null,
            "status": .string(r.text("status") ?? ""), "backfilled": .bool(r.int("backfilled") == 1),
            "after_seal": .bool(r.int("after_seal") == 1), "export": .string(r.text("export") ?? ""),
        ]
    }

    /// The stored task as the JSON `plan.added` carries.
    private func taskJSON(_ id: String, db: SQLiteDatabase) throws -> JSONValue? {
        guard let r = try db.first("SELECT * FROM plan_tasks WHERE id = ?", [.text(id)]) else { return nil }
        return [
            "id": .string(id), "day": .string(r.text("day") ?? ""), "position": .int(r.int("position") ?? 0),
            "title": .string(r.text("title") ?? ""), "ticket": Self.ticketJSON(r),
            "estimate_min": r.int("estimate_min").map(JSONValue.int) ?? .null, "origin": .string(r.text("origin") ?? ""),
            "carried_from": r.text("carried_from").map(JSONValue.string) ?? .null, "status": .string(r.text("status") ?? ""),
            "reason": r.text("reason").map(JSONValue.string) ?? .null,
            "reason_note": r.text("reason_note").map(JSONValue.string) ?? .null,
            "linked_entries": try stored(r.text("linked_entries")), "planned_at": .string(r.text("planned_at") ?? ""),
            "resolved_at": r.text("resolved_at").map(JSONValue.string) ?? .null,
        ]
    }

    private static func ticketJSON(_ r: SQLRow) -> JSONValue {
        guard let key = r.text("ticket_key"), let cls = r.text("ticket_class") else { return .null }
        return ["key": .string(key), "class": .string(cls)]
    }

    private func stored(_ text: String?) throws -> JSONValue {
        do {
            return try JSONParser.parse(text ?? "null")
        } catch {
            throw CadenceError.integrity("a stored projection value is not JSON: \(error)")
        }
    }

    private func touchDay(_ date: String, seq: SQLValue, db: SQLiteDatabase) throws {
        try db.run("UPDATE days SET updated_seq = ? WHERE date = ?", [seq, .text(date)])
    }

    /// First activity is the earliest instant seen, last activity the latest (compared as instants,
    /// so mixed offsets order correctly). Stored text is the event's own text.
    private func widenActivity(day: String, first: String?, last: String?, db: SQLiteDatabase) throws {
        guard let row = try db.first("SELECT first_activity, last_activity FROM days WHERE date = ?", [.text(day)]) else { return }
        if let first, Self.earlier(first, than: row.text("first_activity")) {
            try db.run("UPDATE days SET first_activity = ? WHERE date = ?", [.text(first), .text(day)])
        }
        if let last, Self.later(last, than: row.text("last_activity")) {
            try db.run("UPDATE days SET last_activity = ? WHERE date = ?", [.text(last), .text(day)])
        }
    }

    static func earlier(_ candidate: String, than current: String?) -> Bool {
        guard let current else { return true }
        guard let a = Timestamp.parse(candidate), let b = Timestamp.parse(current) else { return candidate < current }
        return a < b
    }

    static func later(_ candidate: String, than current: String?) -> Bool {
        guard let current else { return true }
        guard let a = Timestamp.parse(candidate), let b = Timestamp.parse(current) else { return candidate > current }
        return a > b
    }

    private func subjectID(_ event: Event, prefix: String) throws -> String {
        guard let subject = event.subject, subject.hasPrefix(prefix), subject.count > prefix.count else {
            throw CadenceError.integrity("event \(event.seq) (\(event.type)) needs a subject starting with \(prefix)")
        }
        return String(subject.dropFirst(prefix.count))
    }

    private func requireChanged(_ db: SQLiteDatabase, _ what: String, event: Event) throws {
        if try db.first("SELECT changes() AS n")?.int("n") == 0 {
            throw CadenceError.integrity("event \(event.seq) (\(event.type)) refers to an unknown \(what)")
        }
    }

    private func canonical(_ value: JSONValue) throws -> String {
        do {
            return try CanonicalJSON.string(value)
        } catch {
            throw CadenceError.integrity("cannot canonicalise a projection value: \(error)")
        }
    }

    private func canonical(_ values: [JSONValue]) throws -> String { try canonical(.array(values)) }

    private func sql(_ db: SQLiteDatabase, _ body: () throws -> Void) throws(CadenceError) {
        do {
            try body()
        } catch let error as CadenceError {
            throw error
        } catch let error as SQLiteError {
            throw error.isConstraint ? .integrity(error.message) : error.cadenceError
        } catch {
            throw .io(String(describing: error))
        }
    }
}

extension SQLiteStore {
    /// `cadence rebuild`: empties every projection and replays the whole ledger in one transaction.
    public func rebuild(batch: Int = 2000) throws(CadenceError) {
        try transact { () throws(CadenceError) -> Void in
            try self.projector.reset(in: self.db)
            var after: Int64 = 0
            while true {
                let page = try self.readEvents(
                    "SELECT * FROM events WHERE seq > ? ORDER BY seq LIMIT ?", [.int(after), .int(Int64(batch))])
                if page.isEmpty { break }
                for event in page { try self.projector.apply(event, in: self.db) }
                after = page[page.count - 1].seq
            }
        }
    }

    /// Every projection table as canonical JSON lines, ordered by primary key. Two stores with the
    /// same ledger produce identical dumps; `cadence rebuild` is checked against this.
    public func projectionDump() throws(CadenceError) -> String {
        let orders: [(String, String)] = [
            ("days", "date"), ("entries", "id"), ("plan_tasks", "id"), ("presence_spans", "id"),
            ("genai_sessions", "session_id"), ("genai_usage", "day, tool, model, source"), ("meta", "key"),
        ]
        var lines: [String] = []
        do {
            for (table, order) in orders {
                for row in try db.query("SELECT * FROM \(table) ORDER BY \(order)") {
                    var object: [String: JSONValue] = ["_table": .string(table)]
                    for (column, value) in zip(row.columns, row.values) {
                        switch value {
                        case .null: object[column] = .null
                        case .int(let i): object[column] = .int(i)
                        case .text(let s): object[column] = .string(s)
                        case .blob(let b): object[column] = .string("blob:\(b.count)")
                        }
                    }
                    lines.append(try CanonicalJSON.string(.object(object)))
                }
            }
        } catch let error as SQLiteError {
            throw error.cadenceError
        } catch {
            throw .io(String(describing: error))
        }
        return lines.joined(separator: "\n")
    }
}
