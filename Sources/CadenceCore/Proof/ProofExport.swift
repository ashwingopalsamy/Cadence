import Foundation

/// What to export and how to label it.
public struct ProofRequest: Sendable {
    public var from: LocalDate
    public var to: LocalDate
    /// The zone the range is read in: the profile zone.
    public var zone: String
    public var name: String?
    public var role: String?
    public var rules: DayRules
    public var generatedAt: Date

    public init(
        from: LocalDate, to: LocalDate, zone: String, name: String? = nil, role: String? = nil,
        rules: DayRules = DayRules(), generatedAt: Date
    ) {
        self.from = from
        self.to = to
        self.zone = zone
        self.name = name
        self.role = role
        self.rules = rules
        self.generatedAt = generatedAt
    }
}

/// A finished export: the file's bytes and what a summary line needs.
public struct ProofFile: Sendable, Equatable {
    public let json: JSONValue
    /// Canonical JSON plus a final newline. Canonical, so the same store and request give the same bytes.
    public let bytes: [UInt8]
    public let events: Int
    public let items: Int
    public let privateEvents: Int
    public let witnesses: Int
    public let exportDigest: String
}

/// Writes cadence.proof/1 (docs/SPEC.md section 12).
///
/// - The chain is every event from genesis to the head, in order. An event carries its payload only
///   when it belongs to a day in the range and nothing marks it private; otherwise it carries hashes
///   only, which still lets the verifier check every link.
/// - An event belongs to the day its subject names (`day:`, `usage:`), or to the current day of the
///   entry, task or session it is about. Events about the ledger itself belong to the local date
///   they were recorded on.
/// - Private means: an entry whose export policy is `digest` or `exclude`, or whose status is not
///   `accepted` (proposed, dismissed and deleted entries never leave the Mac with their text).
///   `digest` items appear in `days` as redacted stubs; `exclude` items do not appear at all. Both
///   are counted in `summary.private_events`, so redaction is visible.
/// - Summary numbers count only items present in `days`, and each one carries its definition.
///
/// Read-only: an export never appends to the ledger.
public enum ProofExporter {
    public static let format = "cadence.proof/1"
    public static let checks = ["export_digest", "sequence", "links", "payload_digests", "event_hashes", "references", "witnesses"]

    public static func export(_ store: SQLiteStore, _ request: ProofRequest) throws(CadenceError) -> ProofFile {
        guard request.from <= request.to else { throw .usage("the range starts after it ends") }
        guard let zone = TimeZone(identifier: request.zone) else { throw .validation("unknown time zone \(request.zone)") }
        return try store.transactRead { () throws(CadenceError) -> ProofFile in
            try Builder(store: store, request: request, zone: zone).build()
        }
    }
}

extension SQLiteStore {
    /// Runs `body` in one read transaction, so a multi-query read sees a single snapshot even while
    /// other processes append.
    func transactRead<T>(_ body: () throws(CadenceError) -> T) throws(CadenceError) -> T {
        do {
            return try db.transaction(.deferred) { () throws -> T in try body() }
        } catch let error as CadenceError {
            throw error
        } catch let error as SQLiteError {
            throw error.cadenceError
        } catch {
            throw .io(String(describing: error))
        }
    }
}

private struct Builder {
    let store: SQLiteStore
    let request: ProofRequest
    let zone: TimeZone

    struct EntryRow {
        let id: String
        let day: String
        let kind: String
        let family: String
        let title: String
        let occurredAt: String?
        let origin: String
        let source: String?
        let ticketKey: String?
        let ticketClass: String?
        let links: JSONValue
        let status: String
        let export: String
        let backfilled: Bool
        let afterSeal: Bool
        let createdSeq: Int64
        let updatedSeq: Int64

        var isPublic: Bool { status == "accepted" && export == "include" }
        var isListed: Bool { status == "accepted" && export != "exclude" }
    }

    func build() throws(CadenceError) -> ProofFile {
        let inRange = { (day: String) -> Bool in
            guard let d = LocalDate(day) else { return false }
            return d >= self.request.from && d <= self.request.to
        }

        // Projections give each entry, task and session its current day and policy.
        let entries = try query("SELECT * FROM entries ORDER BY created_seq").map { r in
            EntryRow(
                id: r.text("id") ?? "", day: r.text("day") ?? "", kind: r.text("kind") ?? "", family: r.text("family") ?? "",
                title: r.text("title") ?? "", occurredAt: r.text("occurred_at"), origin: r.text("origin") ?? "",
                source: r.text("source"), ticketKey: r.text("ticket_key"), ticketClass: r.text("ticket_class"),
                links: (try? JSONParser.parse(r.text("links") ?? "[]")) ?? [], status: r.text("status") ?? "",
                export: r.text("export") ?? "", backfilled: r.int("backfilled") == 1, afterSeal: r.int("after_seal") == 1,
                createdSeq: r.int("created_seq") ?? 0, updatedSeq: r.int("updated_seq") ?? 0)
        }
        var entryByID: [String: EntryRow] = [:]
        for e in entries { entryByID[e.id] = e }
        var taskDay: [String: String] = [:]
        for r in try query("SELECT id, day FROM plan_tasks") { taskDay[r.text("id") ?? ""] = r.text("day") }
        var sessionDay: [String: String] = [:]
        for r in try query("SELECT session_id, day FROM genai_sessions") { sessionDay[r.text("session_id") ?? ""] = r.text("day") }

        // The chain, genesis to head.
        var chain: [JSONValue] = []
        var hashBySeq: [Int64: String] = [:]
        var privateEvents = 0
        var declared: [String: DayKind] = [:]
        var after: Int64 = 0
        while true {
            let page: [Event]
            do { page = try store.events(after: after, limit: 2000) } catch { throw Self.cadence(error) }
            if page.isEmpty { break }
            for event in page {
                hashBySeq[event.seq] = event.hash
                var day: String? = nil
                var isPrivate = false
                let subject = event.subject ?? ""
                if subject.hasPrefix("day:") {
                    day = String(subject.dropFirst(4))
                } else if subject.hasPrefix("usage:") {
                    day = subject.split(separator: ":").dropFirst().first.map(String.init)
                } else if subject.hasPrefix("entry:") {
                    let entry = entryByID[String(subject.dropFirst(6))]
                    day = entry?.day
                    isPrivate = !(entry?.isPublic ?? false)
                } else if subject.hasPrefix("task:") {
                    day = taskDay[String(subject.dropFirst(5))]
                } else if subject.hasPrefix("session:") {
                    day = sessionDay[String(subject.dropFirst(8))]
                }
                if day == nil, let at = Timestamp.parse(event.at) {
                    day = LocalDate.fromEpochDays(LocalDate.floorDiv(Timestamp.localSeconds(at, in: zone), 86_400)).description
                }
                if event.type == "day.declared", let d = day, case .dayDeclared(let p)? = try? EventPayload(type: event.type, data: event.data) {
                    declared[d] = p.kind
                }
                var e: [String: JSONValue] = [
                    "v": .int(event.v), "seq": .int(event.seq), "id": .string(event.id), "at": .string(event.at),
                    "actor": .string(event.actor.rawValue), "type": .string(event.type),
                    "subject": event.subject.map(JSONValue.string) ?? .null, "data_digest": .string(event.dataDigest),
                    "prev": .string(event.prev), "hash": .string(event.hash),
                ]
                let dayInRange = day.map(inRange) ?? false
                if dayInRange && isPrivate { privateEvents += 1 }
                if dayInRange && !isPrivate { e["data"] = event.data }
                chain.append(.object(e))
            }
            after = page.last!.seq
        }

        // Days: every date in range that has a row, plus workdays without one, so a missing day shows.
        var dayRows: [String: SQLRow] = [:]
        for r in try query("SELECT * FROM days WHERE date >= ? AND date <= ?", [.text(request.from.description), .text(request.to.description)]) {
            dayRows[r.text("date") ?? ""] = r
        }
        var aiDays = Set<String>()
        for r in try query("SELECT DISTINCT day FROM genai_sessions UNION SELECT DISTINCT day FROM genai_usage") {
            if let d = r.text("day") { aiDays.insert(d) }
        }
        let entriesByDay = Dictionary(grouping: entries.filter { $0.isListed && inRange($0.day) }, by: \.day)

        var days: [JSONValue] = []
        var countable: [String] = []  // workdays whose outcome is final, for sealed and AI counts
        var sealedInGrace = 0
        for date in LocalDate.range(request.from, through: request.to) {
            let key = date.description
            let row = dayRows[key]
            let kind = request.rules.kind(of: date, declared: declared[key])
            let items = entriesByDay[key] ?? []
            if row == nil && kind != .workday && items.isEmpty { continue }
            let dayZone = row?.text("tz").flatMap(TimeZone.init(identifier:)) ?? zone
            var d: [String: JSONValue] = ["date": .string(key), "kind": .string(kind.rawValue)]
            if let label = row?.text("label") { d["label"] = .string(label) }
            d["first_activity"] = clock(row?.text("first_activity"), dayZone)
            d["last_activity"] = clock(row?.text("last_activity"), dayZone)
            let sealedAt = row?.text("sealed_at").flatMap(Timestamp.parse)
            d["sealed_at"] = sealedAt.map { .string(Timestamp.local($0, in: dayZone)) } ?? .null
            d["seal_ev"] = row?.text("seal_event").map(JSONValue.string) ?? .null
            d["items"] = .array(items.map { item($0, hashBySeq: hashBySeq, zone: dayZone) })
            days.append(.object(d))

            if kind == .workday {
                let counts = sealedAt.map { request.rules.sealCounts($0, for: date, in: dayZone) } ?? false
                if counts || request.rules.graceClosed(for: date, at: request.generatedAt, in: dayZone) {
                    countable.append(key)
                    if counts { sealedInGrace += 1 }
                }
            }
        }

        // Summary.
        let listed = entries.filter { $0.isListed && inRange($0.day) }
        let merged = listed.filter { $0.kind == EntryKind.prMerged.rawValue && $0.origin == Origin.collected.rawValue }
        let reviews = listed.filter { $0.kind == EntryKind.reviewGiven.rawValue }
        let tasks = try query(
            "SELECT day, status, resolved_at FROM plan_tasks WHERE day >= ? AND day <= ? AND status != 'moved'",
            [.text(request.from.description), .text(request.to.description)])
        let doneOnDay = tasks.filter { r in
            guard r.text("status") == "done", let day = r.text("day").flatMap(LocalDate.init),
                let at = r.text("resolved_at").flatMap(Timestamp.parse)
            else { return false }
            let tz = dayRows[day.description]?.text("tz").flatMap(TimeZone.init(identifier:)) ?? zone
            return request.rules.boundary.day(of: at, in: tz) <= day
        }
        let summary: JSONValue = [
            "sealed_workdays": [
                "value": .int(Int64(sealedInGrace)), "of": .int(Int64(countable.count)),
                "definition": "Workdays wrapped up by 23:59 the next day; leave and holidays excluded, and days still inside that window are not counted yet",
            ],
            "plan_done": [
                "value": .int(Int64(doneOnDay.count)), "of": .int(Int64(tasks.count)),
                "definition": "Planned tasks marked done by the end of their day; tasks moved to another day count on that day",
            ],
            "merged_prs": [
                "value": .int(Int64(merged.count)),
                "assigned": .int(Int64(merged.filter { $0.ticketClass == TicketClass.assigned.rawValue }.count)),
                "self_initiated": .int(Int64(merged.filter { $0.ticketClass == TicketClass.selfInitiated.rawValue }.count)),
                "definition": "Merged PRs authored, from the GitHub collector; assigned and self-initiated by ticket, the rest have no ticket",
            ],
            "reviews": [
                "value": .int(Int64(reviews.count)),
                "definition": "Review entries, one per PR per day",
            ],
            "ai_days": [
                "value": .int(Int64(countable.filter(aiDays.contains).count)), "of": .int(Int64(countable.count)),
                "definition": "Counted workdays with a Claude Code session or usage record",
            ],
            "private_events": [
                "value": .int(Int64(privateEvents)),
                "definition": "Events in range exported as hashes only: entries marked digest or exclude, and entries not accepted",
            ],
        ]

        let witnesses = try store.witnesses(from: request.from, through: request.to)
        var subject: [String: JSONValue] = [:]
        if let name = request.name { subject["name"] = .string(name) }
        if let role = request.role { subject["role"] = .string(role) }

        let body: [String: JSONValue] = [
            "format": .string(ProofExporter.format),
            "generated_at": .string(Timestamp.local(request.generatedAt, in: zone)),
            "generator": .string("Cadence \(CadenceVersion.app)"),
            "subject": .object(subject),
            "range": ["from": .string(request.from.description), "to": .string(request.to.description), "tz": .string(request.zone)],
            "how_to_verify": .string(ProofText.howToVerify),
            "verifier_py": .string(ProofText.verifierPython),
            "summary": summary,
            "days": .array(days),
            "chain": ["algo": "sha256", "c14n": "cadence-c14n/1", "events": .array(chain)],
            "witnesses": .array(witnesses.map { w in
                ["date": .string(w.date.description), "code": .string(w.code), "where": .string(w.where)]
            }),
            "checks": .array(ProofExporter.checks.map(JSONValue.string)),
        ]
        let digest: String
        var file = body
        let bytes: [UInt8]
        do {
            digest = store.hashing.hasher.sha256Hex(try CanonicalJSON.bytes(.object(body)))
            file["export_digest"] = .string(digest)
            bytes = try CanonicalJSON.bytes(.object(file)) + [0x0A]
        } catch {
            throw .integrity("the proof is not canonical JSON: \(error)")
        }
        return ProofFile(
            json: .object(file), bytes: bytes, events: chain.count, items: listed.count, privateEvents: privateEvents,
            witnesses: witnesses.count, exportDigest: digest)
    }

    private func item(_ e: EntryRow, hashBySeq: [Int64: String], zone: TimeZone) -> JSONValue {
        let ev = JSONValue.string(hashBySeq[e.createdSeq] ?? "")
        let last = JSONValue.string(hashBySeq[e.updatedSeq] ?? "")
        if e.export == "digest" {
            return ["ev": ev, "last_ev": last, "kind": .string(e.kind), "origin": .string(e.origin), "redacted": true]
        }
        let urls = (e.links.arrayValue ?? []).compactMap { $0.objectValue?["url"] }
        return [
            "ev": ev, "last_ev": last, "kind": .string(e.kind), "family": .string(e.family), "title": .string(e.title),
            "occurred_at": e.occurredAt.flatMap(Timestamp.parse).map { .string(Timestamp.local($0, in: zone)) } ?? .null,
            "origin": .string(e.origin), "source": e.source.map(JSONValue.string) ?? .null,
            "ticket": e.ticketKey.map { ["key": .string($0), "class": e.ticketClass.map(JSONValue.string) ?? .null] } ?? .null,
            "links": .array(urls),
            "flags": ["edited": .bool(e.updatedSeq != e.createdSeq), "after_seal": .bool(e.afterSeal), "backfilled": .bool(e.backfilled)],
        ]
    }

    private func clock(_ text: String?, _ zone: TimeZone) -> JSONValue {
        guard let date = text.flatMap(Timestamp.parse) else { return .null }
        return .string(Timestamp.clockTime(date, in: zone))
    }

    private func query(_ sql: String, _ parameters: [SQLValue] = []) throws(CadenceError) -> [SQLRow] {
        do { return try store.db.query(sql, parameters) } catch { throw error.cadenceError }
    }

    static func cadence(_ error: any Error) -> CadenceError {
        (error as? CadenceError) ?? .io(String(describing: error))
    }
}
