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
        from: LocalDate, to: LocalDate, zone: String, name: String? = nil, role: String? = nil, rules: DayRules,
        generatedAt: Date
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
/// - Payloads are allow-listed (`exportablePayload`): only event types whose fields are work facts
///   carry data. Free text that is the owner's own (day notes, focus lines, reason notes, status
///   notes, collector errors, day labels) and every event type this binary does not know stay
///   hash-only. Entries carry data only when accepted with policy `include`; proposed, dismissed and
///   deleted entries never leave the Mac with their text. `digest` items appear in `days` as
///   redacted stubs; `exclude` items do not appear at all. Every hash-only event in range is counted
///   in `summary.private_events`, so redaction is visible.
/// - A day's seal is its first seal: sealing again later never undoes one that counted.
/// - Summary numbers count only items present in `days`, and each one carries its definition. Days
///   before the ledger began are not counted as unsealed: they are reported as `before_ledger`.
///
/// Read-only: an export never appends to the ledger.
public enum ProofExporter {
    public static let format = "cadence.proof/1"
    public static let checks = ["export_digest", "sequence", "links", "payload_digests", "event_hashes", "references", "witnesses"]

    /// A proof covers at most this many days (about three years).
    public static let maxDays = 1100

    public static func export(_ store: SQLiteStore, _ request: ProofRequest) throws(CadenceError) -> ProofFile {
        guard request.from <= request.to else { throw .usage("the range starts after it ends") }
        guard request.from.days(until: request.to) < maxDays else {
            throw .usage("a proof covers at most \(maxDays) days; export a shorter range")
        }
        guard let zone = TimeZone(identifier: request.zone) else { throw .validation("unknown time zone \(request.zone)") }
        return try store.transactRead { () throws(CadenceError) -> ProofFile in
            try Builder(store: store, request: request, zone: zone).build()
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
        let status: EntryStatus?
        let export: ExportPolicy?
        let backfilled: Bool
        let afterSeal: Bool
        let createdSeq: Int64
        let updatedSeq: Int64

        var isPublic: Bool { status == .accepted && export == .include }
        var isListed: Bool { status == .accepted && (export == .include || export == .digest) }
    }

    /// Whether an in-range event of a known type may carry its payload. Everything not named here,
    /// including types a newer binary adds, is hash-only.
    static func exportablePayload(_ event: Event, entry: EntryRow?) -> Bool {
        let data = event.data.objectValue ?? [:]
        func isNull(_ key: String) -> Bool { data[key] == nil || data[key] == .null }
        switch event.type {
        case "ledger.genesis", "day.started", "day.ended", "presence.span", "plan.added", "plan.updated",
            "day.sealed", "witness.checkpoint", "genai.session", "genai.usage":
            return true
        case "day.declared": return isNull("label")
        case "plan.resolved": return isNull("reason_note")
        case "plan.committed": return isNull("focus")
        case "entry.created", "entry.updated": return entry?.isPublic ?? false
        case "entry.status": return (entry?.isPublic ?? false) && isNull("note")
        default: return false  // day.noted, ingest.run, config.classifier, unknown types
        }
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
                links: (try? JSONParser.parse(r.text("links") ?? "[]")) ?? [],
                status: r.text("status").flatMap(EntryStatus.init(rawValue:)),
                export: r.text("export").flatMap(ExportPolicy.init(rawValue:)), backfilled: r.int("backfilled") == 1,
                afterSeal: r.int("after_seal") == 1, createdSeq: r.int("created_seq") ?? 0,
                updatedSeq: r.int("updated_seq") ?? 0)
        }
        var entryByID: [String: EntryRow] = [:]
        for e in entries { entryByID[e.id] = e }
        var taskDay: [String: String] = [:]
        for r in try query("SELECT id, day FROM plan_tasks") { taskDay[r.text("id") ?? ""] = r.text("day") }
        var sessionDay: [String: String] = [:]
        for r in try query("SELECT session_id, day FROM genai_sessions") { sessionDay[r.text("session_id") ?? ""] = r.text("day") }

        // The chain, genesis to head, collecting what the days need on the way.
        var chain: [JSONValue] = []
        var hashBySeq: [Int64: String] = [:]
        var privateEvents = 0
        var declared: [String: DayKind] = [:]
        var firstSeal: [String: Int64] = [:]  // day -> seq of its first day.sealed
        var updateSeqs: [String: [Int64]] = [:]  // entry id -> seqs of its entry.updated events
        var ledgerStart: LocalDate? = nil
        var after: Int64 = 0
        while true {
            let page: [Event]
            do { page = try store.events(after: after, limit: 2000) } catch { throw Self.cadence(error) }
            if page.isEmpty { break }
            for event in page {
                hashBySeq[event.seq] = event.hash
                var day: String? = nil
                var entry: EntryRow? = nil
                let subject = event.subject ?? ""
                if subject.hasPrefix("day:") {
                    day = String(subject.dropFirst(4))
                } else if subject.hasPrefix("usage:") {
                    day = subject.split(separator: ":").dropFirst().first.map(String.init)
                } else if subject.hasPrefix("entry:") {
                    let id = String(subject.dropFirst(6))
                    entry = entryByID[id]
                    day = entry?.day
                    if event.type == "entry.updated" { updateSeqs[id, default: []].append(event.seq) }
                } else if subject.hasPrefix("task:") {
                    day = taskDay[String(subject.dropFirst(5))]
                } else if subject.hasPrefix("session:") {
                    day = sessionDay[String(subject.dropFirst(8))]
                }
                let recorded = Timestamp.parse(event.at).map { request.rules.boundary.day(of: $0, in: zone) }
                if day == nil { day = recorded?.description }
                if event.type == "ledger.genesis" { ledgerStart = recorded }
                if event.type == "day.declared", let d = day,
                    case .dayDeclared(let p)? = try? EventPayload(type: event.type, data: event.data)
                {
                    declared[d] = p.kind
                }
                if event.type == "day.sealed", let d = day, firstSeal[d] == nil { firstSeal[d] = event.seq }
                var e: [String: JSONValue] = [
                    "v": .int(event.v), "seq": .int(event.seq), "id": .string(event.id), "at": .string(event.at),
                    "actor": .string(event.actor.rawValue), "type": .string(event.type),
                    "subject": event.subject.map(JSONValue.string) ?? .null, "data_digest": .string(event.dataDigest),
                    "prev": .string(event.prev), "hash": .string(event.hash),
                ]
                if day.map(inRange) ?? false {
                    if Self.exportablePayload(event, entry: entry) {
                        e["data"] = event.data
                    } else {
                        privateEvents += 1
                    }
                }
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
        for r in try query("SELECT DISTINCT day FROM genai_sessions UNION SELECT DISTINCT day FROM genai_usage WHERE sessions > 0") {
            if let d = r.text("day") { aiDays.insert(d) }
        }
        let firstAIDay = aiDays.min()
        let entriesByDay = Dictionary(grouping: entries.filter { $0.isListed && inRange($0.day) }, by: \.day)

        var days: [JSONValue] = []
        var countable: [String] = []  // workdays since the ledger began whose outcome is final
        var beforeLedger = 0
        var sealedInGrace = 0
        for date in LocalDate.range(request.from, through: request.to) {
            let key = date.description
            let row = dayRows[key]
            let kind = request.rules.kind(of: date, declared: declared[key])
            let items = entriesByDay[key] ?? []
            if row == nil && kind != .workday && items.isEmpty { continue }
            let dayZone = row?.text("tz").flatMap(TimeZone.init(identifier:)) ?? zone
            let sealSeq = firstSeal[key]
            let sealHash = sealSeq.flatMap { hashBySeq[$0] }
            let sealedAt = row?.text("sealed_at").flatMap(Timestamp.parse)
            var d: [String: JSONValue] = ["date": .string(key), "kind": .string(kind.rawValue)]
            d["first_activity"] = clock(row?.text("first_activity"), dayZone)
            d["last_activity"] = clock(row?.text("last_activity"), dayZone)
            d["sealed_at"] = sealedAt.map { .string(Timestamp.local($0, in: dayZone)) } ?? .null
            d["seal_ev"] = sealHash.map(JSONValue.string) ?? .null
            d["items"] = .array(items.map { entry in
                // Edited means changed after the day's wrap-up: an entry.updated after the first seal.
                let edited = sealSeq.map { seal in (updateSeqs[entry.id] ?? []).contains { $0 > seal } } ?? false
                return item(entry, edited: edited, hashBySeq: hashBySeq, zone: dayZone)
            })
            days.append(.object(d))

            guard kind == .workday else { continue }
            if let start = ledgerStart, date < start {
                beforeLedger += 1
                continue
            }
            let counts = sealedAt.map { request.rules.sealCounts($0, for: date, in: dayZone) } ?? false
            if counts || request.rules.graceClosed(for: date, at: request.generatedAt, in: dayZone) {
                countable.append(key)
                if counts { sealedInGrace += 1 }
            }
        }

        // Summary.
        let countableSet = Set(countable)
        let listed = entries.filter { $0.isListed && inRange($0.day) }
        let merged = listed.filter {
            $0.kind == EntryKind.prMerged.rawValue && $0.origin == Origin.collected.rawValue && $0.source == "github"
        }
        let reviews = listed.filter { $0.kind == EntryKind.reviewGiven.rawValue }
        let tasks = try query(
            "SELECT day, status, resolved_at FROM plan_tasks WHERE day >= ? AND day <= ? AND status != 'moved'",
            [.text(request.from.description), .text(request.to.description)]
        ).filter { countableSet.contains($0.text("day") ?? "") }
        let doneOnDay = tasks.filter { r in
            guard r.text("status") == "done", let day = r.text("day").flatMap(LocalDate.init),
                let at = r.text("resolved_at").flatMap(Timestamp.parse)
            else { return false }
            let tz = dayRows[day.description]?.text("tz").flatMap(TimeZone.init(identifier:)) ?? zone
            return request.rules.boundary.day(of: at, in: tz) <= day
        }
        let aiCountable = countable.filter { day in firstAIDay.map { day >= $0 } ?? false }
        let summary: JSONValue = [
            "sealed_workdays": [
                "value": .int(Int64(sealedInGrace)), "of": .int(Int64(countable.count)),
                "before_ledger": .int(Int64(beforeLedger)),
                "definition": "Workdays wrapped up by 23:59 the next day, counted from the day the ledger began; leave and holidays excluded, days still inside that window not counted yet, and workdays before the ledger began reported as before_ledger",
            ],
            "plan_done": [
                "value": .int(Int64(doneOnDay.count)), "of": .int(Int64(tasks.count)),
                "definition": "Planned tasks on counted workdays marked done by the end of their day; tasks moved to another day count on that day",
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
                "value": .int(Int64(aiCountable.filter(aiDays.contains).count)), "of": .int(Int64(aiCountable.count)),
                "definition": "Counted workdays with an AI coding session or usage record, from the first day any AI source recorded",
            ],
            "private_events": [
                "value": .int(Int64(privateEvents)),
                "definition": "Events in range exported as hashes only: private notes and reasons, entries marked digest or exclude, and entries not accepted",
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

    private func item(_ e: EntryRow, edited: Bool, hashBySeq: [Int64: String], zone: TimeZone) -> JSONValue {
        let ev = JSONValue.string(hashBySeq[e.createdSeq] ?? "")
        let last = JSONValue.string(hashBySeq[e.updatedSeq] ?? "")
        let flags: JSONValue = ["edited": .bool(edited), "after_seal": .bool(e.afterSeal), "backfilled": .bool(e.backfilled)]
        if e.export == .digest {
            return ["ev": ev, "last_ev": last, "kind": .string(e.kind), "origin": .string(e.origin), "redacted": true, "flags": flags]
        }
        let urls = (e.links.arrayValue ?? []).compactMap { $0.objectValue?["url"] }
        return [
            "ev": ev, "last_ev": last, "kind": .string(e.kind), "family": .string(e.family), "title": .string(e.title),
            "occurred_at": e.occurredAt.flatMap(Timestamp.parse).map { .string(Timestamp.local($0, in: zone)) } ?? .null,
            "origin": .string(e.origin), "source": e.source.map(JSONValue.string) ?? .null,
            "ticket": e.ticketKey.map { ["key": .string($0), "class": e.ticketClass.map(JSONValue.string) ?? .null] } ?? .null,
            "links": .array(urls), "flags": flags,
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
