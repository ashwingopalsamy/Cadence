import Foundation

/// The window a run asked the collector for. `ingest.run` records it, whatever the envelope claims.
public struct IngestWindow: Sendable, Equatable {
    public var since: String
    public var until: String

    public init(since: String, until: String) {
        self.since = since
        self.until = until
    }
}

/// What one run did. `counts` is empty when the run failed, because nothing was counted.
public struct IngestReport: Sendable, Equatable {
    public static let countKeys = ["records", "created", "updated", "unchanged", "ignored", "skipped", "warnings"]

    public var runID: String
    public var collector: String
    /// "ok" or "error".
    public var status: String
    public var counts: [String: Int64]
    /// One line per skipped record, warning or failure, as `ingest.run` stores them.
    public var problems: [String]
    /// Where the envelope was kept because something in it was skipped or unreadable.
    public var inbox: URL?

    public func count(_ key: String) -> Int64 { counts[key] ?? 0 }
}

extension Journal {
    static let maxRunErrors = 50
    static let maxRunError = 300
    /// Collected presence shorter than this is not worth a span.
    static let minPresenceGap: TimeInterval = 60

    /// Validates an `envelope/1` and writes what it holds (docs/SPEC.md section 10.1), with one `ingest.run`,
    /// all in one transaction. A bad record is skipped and counted; an unreadable header or an envelope over
    /// the limits writes only a failed `ingest.run`. When anything was skipped or unreadable the envelope is
    /// kept in `inbox` (when given) with a note of why.
    ///
    /// - Parameters:
    ///   - collector: the configured collector name; the header must name it.
    ///   - actor: `collector:<name>` by default, `import:<name>` for imports.
    ///   - skipped: records already dropped before the envelope was made, such as rows a map could not read.
    ///     They count as skipped and keep the envelope in `inbox`.
    @discardableResult
    public func ingest(
        envelope bytes: [UInt8], collector: String, window: IngestWindow, actor: Actor? = nil, inbox: URL? = nil,
        skipped: [String] = []
    ) throws(CadenceError) -> IngestReport {
        guard Actor.isValidName(collector) else { throw .validation("collector: '\(collector)' is not a valid name") }
        let actor = actor ?? .collector(collector)
        guard actor == .collector(collector) || actor == .importer(collector) else {
            throw .validation("actor: must be collector:\(collector) or import:\(collector)")
        }
        let runID = ids.next()

        let parts: (header: (Int, ArraySlice<UInt8>), records: [(Int, ArraySlice<UInt8>)])
        do {
            parts = try EnvelopeReader.split(bytes)
            _ = try EnvelopeReader.header(parts.header.1, collector: collector)
        } catch {
            let report = try recordRun(runID: runID, collector: collector, window: window, actor: actor, status: "error",
                                       counts: [:], problems: [error.message])
            return keep(bytes, report: report, inbox: bytes.count <= EnvelopeReader.maxBytes ? inbox : nil)
        }

        let reader = EnvelopeReader(context: EnvelopeContext(
            now: clock.now(), zone: zone, boundary: config.dayBoundary, classifier: classifier,
            httpHosts: Set(config.hosts.map { $0.lowercased() })))
        let lines = parts.records.map { reader.line($0.0, $0.1) }

        var counts: [String: Int64] = [:]
        for key in IngestReport.countKeys { counts[key] = 0 }
        counts["records"] = Int64(lines.count + skipped.count)
        counts["skipped"] = Int64(skipped.count)
        var problems = skipped.map { "map: \($0)" }

        let report = try store.transact { () throws(CadenceError) -> IngestReport in
            // A key a record writes to. A second record for the same key in one envelope is skipped, so the
            // envelope settles: the next run of it writes nothing instead of flipping between the two.
            var seen: [String: Int] = [:]
            for line in lines {
                var outcome: IngestOutcome
                switch line.record {
                case .failure(let error):
                    outcome = .skipped(error.message)
                case .success(let record):
                    if let key = Self.key(record), let first = seen[key] {
                        outcome = .skipped("repeats what line \(first) already says about \(Self.printableKey(key))")
                        break
                    }
                    if let key = Self.key(record) { seen[key] = line.number }
                    // Each record in its own savepoint: one the ledger refuses is skipped and leaves nothing behind.
                    do throws(CadenceError) {
                        outcome = try self.store.transact { () throws(CadenceError) -> IngestOutcome in
                            let result = try self.write(record, collector: collector, actor: actor)
                            if case .skipped(let why) = result { throw .validation(why) }
                            return result
                        }
                    } catch {
                        switch error {
                        case .validation, .integrity: outcome = .skipped(error.message)
                        default: throw error  // a busy or failing store stops the run; it is not the record's fault
                        }
                    }
                    for warning in line.warnings {
                        counts["warnings", default: 0] += 1
                        problems.append("line \(line.number): warning: \(warning)")
                    }
                }
                switch outcome {
                case .created: counts["created", default: 0] += 1
                case .updated: counts["updated", default: 0] += 1
                case .unchanged: counts["unchanged", default: 0] += 1
                case .ignored: counts["ignored", default: 0] += 1
                case .skipped(let why):
                    counts["skipped", default: 0] += 1
                    problems.append("line \(line.number): \(why)")
                }
            }
            return try self.recordRun(runID: runID, collector: collector, window: window, actor: actor, status: "ok",
                                      counts: counts, problems: problems)
        }
        return keep(bytes, report: report, inbox: counts["skipped"] ?? 0 > 0 ? inbox : nil)
    }

    /// Records a run that produced nothing to read: a non-zero exit, a timeout, a refused command.
    @discardableResult
    public func recordIngestFailure(
        collector: String, window: IngestWindow, error: String, actor: Actor? = nil
    ) throws(CadenceError) -> IngestReport {
        guard Actor.isValidName(collector) else { throw .validation("collector: '\(collector)' is not a valid name") }
        return try recordRun(runID: ids.next(), collector: collector, window: window, actor: actor ?? .collector(collector),
                             status: "error", counts: [:], problems: [error])
    }

    // MARK: - Records

    enum IngestOutcome: Equatable {
        case created, updated, unchanged
        /// Valid, but nothing may change: every difference is in a field you own, or you declared the day.
        case ignored
        case skipped(String)
    }

    private func write(_ record: EnvelopeRecord, collector: String, actor: Actor) throws(CadenceError) -> IngestOutcome {
        switch record {
        case .item(let item): return try writeItem(item, collector: collector, actor: actor)
        case .usage(let usage): return try writeUsage(usage, collector: collector, actor: actor)
        case .presence(let span): return try writePresence(span, actor: actor)
        case .leave(let leave): return try writeLeave(leave, actor: actor)
        }
    }

    private func writeItem(_ item: ItemRecord, collector: String, actor: Actor) throws(CadenceError) -> IngestOutcome {
        let dayZone = try zone(of: item.day)
        // The reader placed the time in the profile zone; a day recorded in another zone must agree.
        if let at = item.occurredAt, config.dayBoundary.day(of: at, in: dayZone) != item.day {
            return .skipped("item.occurred_at: is not on \(item.day) in that day's zone \(dayZone.identifier)")
        }
        let occurredAt = item.occurredAt.map { Timestamp.local($0, in: dayZone) }
        guard let row = try rows("SELECT id, source FROM entries WHERE source_ref = ?", [.text(item.sourceRef)]).first,
            let id = row.text("id")
        else {
            let entry = Entry(
                id: ids.next(), day: item.day.description, kind: item.kind,
                family: EntryKind.family(for: item.kind, ticketClass: item.ticket?.class), title: item.title,
                occurredAt: occurredAt, durationS: item.durationS, quantity: item.quantity, ticket: item.ticket,
                links: item.links, tags: item.tags, attrs: item.attrs, origin: .collected, source: collector,
                sourceRef: item.sourceRef, status: .accepted, backfilled: item.day < today(),
                afterSeal: try isSealed(item.day), export: item.kind == .note ? .digest : .include)
            return try appendChecked(EventPayload.entryCreated(entry).draft(actor: actor))
        }
        // Section 10.1: a collector only edits entries it created.
        guard row.text("source") == collector else {
            return .skipped("item.source_ref: belongs to an entry another writer created")
        }
        let current = try entry(id)
        var wanted = current
        wanted.day = item.day.description
        wanted.kind = item.kind
        wanted.title = item.title
        wanted.occurredAt = occurredAt
        wanted.durationS = item.durationS
        wanted.quantity = item.quantity
        wanted.ticket = item.ticket
        wanted.links = item.links
        wanted.tags = item.tags
        wanted.attrs = item.attrs

        let before = current.json.objectValue ?? [:]
        var after = wanted.json.objectValue ?? [:]
        let fields = ["day", "kind", "title", "occurred_at", "duration_s", "quantity", "ticket", "links", "tags", "attrs"]
        guard fields.contains(where: { before[$0] != after[$0] }) else { return .unchanged }

        // Once you edit a field it is yours: later collector values for it are ignored.
        var owned = Set<String>()
        for event in try store.events(subject: "entry:\(id)") where event.type == "entry.updated" && !Self.isMachine(event.actor) {
            if let keys = event.data.objectValue?["changes"]?.objectValue?.keys { owned.formUnion(keys) }
        }
        for field in owned { after[field] = before[field] }
        if !owned.contains("family"), let kind = after["kind"]?.stringValue.flatMap(EntryKind.init(rawValue:)) {
            let ticketClass = after["ticket"]?.objectValue?["class"]?.stringValue.flatMap(TicketClass.init(rawValue:))
            after["family"] = .string(EntryKind.family(for: kind, ticketClass: ticketClass).rawValue)
        }
        // An entry that moves onto a day already sealed arrived after wrap-up there.
        if after["day"] != before["day"], let day = after["day"]?.stringValue.flatMap(LocalDate.init), try isSealed(day) {
            after["after_seal"] = .bool(true)
        }

        var changes: [String: Change] = [:]
        for field in fields + ["family", "after_seal"] where before[field] != after[field] {
            changes[field] = Change(old: before[field] ?? .null, new: after[field] ?? .null)
        }
        guard !changes.isEmpty else { return .ignored }
        let outcome = try appendChecked(EventPayload.entryUpdated(Changes(fields: changes)).draft(actor: actor, id: id))
        return outcome == .created ? .updated : outcome
    }

    private func writeUsage(_ usage: UsageRecord, collector: String, actor: Actor) throws(CadenceError) -> IngestOutcome {
        // Section 10.6: imported rows carry source `import:<name>`, so they never collide with a collector's.
        let source = actor == .importer(collector) ? "import:\(collector)" : collector
        let payload = GenAIUsage(
            day: usage.day.description, tool: usage.tool, model: usage.model, source: source, sessions: usage.sessions,
            requests: usage.requests, tokens: usage.tokens, costMicros: usage.costMicros, estimated: usage.estimated)
        // The row's last event is what the row holds, the estimated flag included.
        if let last = try store.events(subject: EventPayload.genaiUsage(payload).subject(id: nil) ?? "").last {
            if (try? GenAIUsage(json: last.data)) == payload { return .unchanged }
            let outcome = try appendChecked(EventPayload.genaiUsage(payload).draft(actor: actor))
            return outcome == .created ? .updated : outcome
        }
        return try appendChecked(EventPayload.genaiUsage(payload).draft(actor: actor))
    }

    /// Section 10.1: collected presence fills gaps only. A span is cut at each day boundary; whatever any span of
    /// that day already covers stays as it is, and only the uncovered pieces are written, so sending the same span
    /// again writes nothing.
    private func writePresence(_ span: PresenceRecord, actor: Actor) throws(CadenceError) -> IngestOutcome {
        // Whole seconds, as the spans are stored, so a resent span compares equal to what it wrote.
        var cursor = Date(timeIntervalSince1970: span.start.timeIntervalSince1970.rounded(.down))
        let end = Date(timeIntervalSince1970: span.end.timeIntervalSince1970.rounded(.down))
        var pieces: [(day: LocalDate, zone: TimeZone, start: Date, end: Date)] = []
        repeat {
            let (day, dayZone) = try workday(of: cursor)
            let next = day.adding(days: 1)
            let dayEnd = Timestamp.resolve(next, hour: config.dayBoundary.hour, minute: config.dayBoundary.minute, in: dayZone)
            let pieceEnd = min(end, dayEnd)
            guard pieceEnd > cursor else { return .skipped("presence.span: cannot place the span on a day") }
            for gap in try gaps(day: day, from: cursor, to: pieceEnd) {
                pieces.append((day, dayZone, gap.0, gap.1))
            }
            cursor = pieceEnd
        } while cursor < end
        guard !pieces.isEmpty else { return .unchanged }
        guard pieces.allSatisfy({ $0.day <= today() }) else { return .skipped("presence.span.start: is in the future") }
        for piece in pieces {
            let payload = PresenceSpanPayload(
                day: piece.day.description, tz: piece.zone.identifier, start: Timestamp.local(piece.start, in: piece.zone),
                end: Timestamp.local(piece.end, in: piece.zone), source: .collected)
            if case .skipped(let why) = try appendChecked(EventPayload.presenceSpan(payload).draft(actor: actor)) {
                return .skipped(why)
            }
        }
        return .created
    }

    /// The parts of `from..<to` that no span of `day` covers, each at least a minute long.
    private func gaps(day: LocalDate, from: Date, to: Date) throws(CadenceError) -> [(Date, Date)] {
        var covered: [(Date, Date)] = []
        for row in try rows("SELECT start_at, end_at FROM presence_spans WHERE day = ?", [.text(day.description)]) {
            if let a = row.text("start_at").flatMap(Timestamp.parse), let b = row.text("end_at").flatMap(Timestamp.parse) {
                covered.append((a, b))
            }
        }
        covered.sort { $0.0 < $1.0 }
        var gaps: [(Date, Date)] = []
        var cursor = from
        for (a, b) in covered where b > cursor && a < to {
            if a > cursor { gaps.append((cursor, a)) }
            cursor = max(cursor, b)
        }
        if cursor < to { gaps.append((cursor, to)) }
        return gaps.filter { $0.1.timeIntervalSince($0.0) >= Self.minPresenceGap }
    }

    /// Section 10.1: `day.declared`, only if you have not declared that day yourself.
    private func writeLeave(_ leave: LeaveRecord, actor: Actor) throws(CadenceError) -> IngestOutcome {
        let declarations = try store.events(subject: "day:\(leave.day)").filter { $0.type == "day.declared" }
        if declarations.contains(where: { $0.actor != actor }) { return .ignored }
        let payload = DayDeclared(day: leave.day.description, tz: try zone(of: leave.day).identifier, kind: leave.kind, label: leave.label)
        if let last = declarations.last, let previous = try? DayDeclared(json: last.data),
            previous.kind == payload.kind, previous.label == payload.label
        {
            return .unchanged
        }
        let outcome = try appendChecked(EventPayload.dayDeclared(payload).draft(actor: actor))
        return outcome == .created && !declarations.isEmpty ? .updated : outcome
    }

    // MARK: - Helpers

    /// Appends one event after checking it decodes as the ledger will, so a record that slipped past the
    /// envelope rules is skipped instead of failing the whole run.
    private func appendChecked(_ draft: EventDraft) throws(CadenceError) -> IngestOutcome {
        do {
            _ = try EventPayload(type: draft.type, data: draft.data)
        } catch {
            return .skipped(error.message)
        }
        try append([draft])
        return .created
    }

    /// The workday an instant falls on and the zone it is read in. The day comes from the same zone as its end,
    /// so the end always lies after the instant.
    private func workday(of instant: Date) throws(CadenceError) -> (LocalDate, TimeZone) {
        let dayZone = try zone(of: config.dayBoundary.day(of: instant, in: zone))
        return (config.dayBoundary.day(of: instant, in: dayZone), dayZone)
    }

    /// Collectors and imports never own a field; you do, through the app, the CLI or an agent.
    static func isMachine(_ actor: Actor) -> Bool {
        switch actor {
        case .collector, .importer: true
        default: false
        }
    }

    private func isSealed(_ day: LocalDate) throws(CadenceError) -> Bool {
        try rows("SELECT sealed_at FROM days WHERE date = ?", [.text(day.description)]).first?.text("sealed_at") != nil
    }

    private func recordRun(
        runID: String, collector: String, window: IngestWindow, actor: Actor, status: String, counts: [String: Int64],
        problems: [String]
    ) throws(CadenceError) -> IngestReport {
        let errors = problems.prefix(Self.maxRunErrors).map { Self.clean($0, limit: Self.maxRunError) }
        let run = IngestRun(collector: collector, since: window.since, until: window.until, counts: counts, errors: Array(errors), status: status)
        try store.transact { () throws(CadenceError) -> Void in
            try self.append([EventPayload.ingestRun(run).draft(actor: actor, id: runID)])
        }
        return IngestReport(runID: runID, collector: collector, status: status, counts: counts, problems: problems, inbox: nil)
    }

    /// Keeps the envelope and the reasons beside it in `inbox`, readable only by you.
    /// The ledger has already committed, so a file that cannot be written leaves `inbox` nil instead of failing the run.
    private func keep(_ bytes: [UInt8], report: IngestReport, inbox: URL?) -> IngestReport {
        guard let inbox else { return report }
        let base = "\(report.collector)-\(report.runID)"
        let file = inbox.appendingPathComponent("\(base).jsonl")
        let why = report.problems.map { Self.clean($0, limit: Self.maxRunError) }.joined(separator: "\n") + "\n"
        do {
            try PrivateFile.save(bytes, to: file)
            try PrivateFile.save(Array(why.utf8), to: inbox.appendingPathComponent("\(base).txt"))
        } catch {
            return report
        }
        var kept = report
        kept.inbox = file
        return kept
    }

    /// What a record writes to, for spotting two records in one envelope that would overwrite each other.
    static func key(_ record: EnvelopeRecord) -> String? {
        switch record {
        case .item(let item): "item\u{0}\(item.sourceRef)"
        case .usage(let usage): "usage\u{0}\(usage.day)\u{0}\(usage.tool)\u{0}\(usage.model)"
        case .leave(let leave): "leave\u{0}\(leave.day)"
        case .presence: nil  // gap filling is already idempotent
        }
    }

    static func printableKey(_ key: String) -> String {
        let parts = key.split(separator: "\u{0}").map(String.init)
        switch parts.first {
        case "item": return "source_ref \(EnvelopeReader.printable(parts[1]))"
        case "usage": return "the usage row for \(parts[1]), \(EnvelopeReader.printable(parts[2])), \(EnvelopeReader.printable(parts[3]))"
        default: return "the day \(parts.last ?? "")"
        }
    }
}
