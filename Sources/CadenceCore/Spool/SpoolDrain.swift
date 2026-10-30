import Foundation

/// What one drain did.
public struct DrainReport: Sendable, Equatable {
    /// `genai.session` events appended.
    public var eventsWritten = 0
    /// Sessions whose lines taught the ledger nothing new (a replay or a lost offset).
    public var duplicates = 0
    /// Valid lines that do not change a session record (stop, task-completed).
    public var ignored = 0
    /// Lines that are not a usable hook line.
    public var skippedMalformed = 0
    /// Files that end in a line without its newline, left for the next drain.
    public var partialFiles = 0
    public var filesDeleted = 0

    public init() {}

    public var json: JSONValue {
        [
            "events_written": .int(Int64(eventsWritten)), "duplicates": .int(Int64(duplicates)),
            "ignored": .int(Int64(ignored)), "skipped_malformed": .int(Int64(skippedMalformed)),
            "partial_files": .int(Int64(partialFiles)), "files_deleted": .int(Int64(filesDeleted)),
        ]
    }

    public var summary: String {
        var parts = ["Spool drained: \(eventsWritten) session \(eventsWritten == 1 ? "event" : "events") written"]
        if duplicates > 0 { parts.append("\(duplicates) already recorded") }
        if skippedMalformed > 0 { parts.append("\(skippedMalformed) malformed \(skippedMalformed == 1 ? "line" : "lines") skipped") }
        if partialFiles > 0 { parts.append("\(partialFiles) unfinished \(partialFiles == 1 ? "line" : "lines") left for later") }
        if filesDeleted > 0 { parts.append("\(filesDeleted) old \(filesDeleted == 1 ? "file" : "files") removed") }
        return parts.joined(separator: ", ")
    }
}

/// Turns the hook spool into `genai.session` events (docs/SPEC.md section 9.3). Safe to run any number of
/// times, from any process:
///
/// - Progress is a byte offset per spool file in `state/spool-drain.json`, saved after each file's transaction.
/// - A lost or stale offset cannot duplicate anything: each session is compared with its `genai_sessions` row
///   inside the same transaction, and an event is written only when it adds a start or a later end.
/// - A last line without its newline is left alone until it is complete.
public final class SpoolDrain {
    public static let tool = "claude-code"
    public static let keepDays = 14
    static let stateName = "spool-drain.json"

    let roots: FileRoots
    let store: SQLiteStore
    let config: Config
    let clock: any Clock
    let genesisActor: Actor

    public init(roots: FileRoots, store: SQLiteStore, config: Config, clock: any Clock, genesisActor: Actor = .cli) {
        self.roots = roots
        self.store = store
        self.config = config
        self.clock = clock
        self.genesisActor = genesisActor
    }

    // MARK: parsing

    struct Line {
        var event: HookEventName
        var sessionId: String
        var at: String
        var date: Date
        var project: String?
        var model: String?
        var reason: String?
    }

    static func parse(_ bytes: ArraySlice<UInt8>) -> Line? {
        guard let object = (try? JSONParser.parse(bytes: Array(bytes)))?.objectValue,
            object["v"]?.intValue == HookSpool.version,
            let name = object["event"]?.stringValue, let event = HookEventName(rawValue: name),
            let sessionId = object["session_id"]?.stringValue, HookSpool.isSafeSessionId(sessionId),
            let at = object["at"]?.stringValue, let date = Timestamp.parse(at)
        else { return nil }
        return Line(
            event: event, sessionId: sessionId, at: at, date: date, project: object["project"]?.stringValue,
            model: object["model"]?.stringValue, reason: object["reason"]?.stringValue)
    }

    /// What the lines of one session in one file add up to.
    struct Fold {
        var first: Line
        var start: Line?
        var end: Line?
    }

    // MARK: drain

    @discardableResult
    public func drain() throws(CadenceError) -> DrainReport {
        var report = DrainReport()
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: roots.spool.path) else { return report }
        let files = names.filter { Self.isSpoolFile($0) }.sorted()
        var offsets = loadOffsets()
        var changed = false

        for name in files {
            let url = roots.spool.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            var offset = offsets[name] ?? 0
            if offset > data.count { offset = 0 }  // the file was replaced by a shorter one
            let bytes = [UInt8](data)
            let end = (bytes.lastIndex(of: 0x0A).map { $0 + 1 }) ?? 0
            let limit = max(end, offset)
            if limit < bytes.count { report.partialFiles += 1 }

            if limit > offset {
                try drainLines(bytes[offset..<limit], into: &report)
                offsets[name] = limit
                changed = true
                try saveOffsets(offsets)
            }
            if limit == bytes.count, Self.isExpired(name, now: clock.now()) {
                if (try? manager.removeItem(at: url)) != nil {
                    report.filesDeleted += 1
                    offsets[name] = nil
                    changed = true
                }
            }
        }
        let known = Set(files)
        for name in offsets.keys where !known.contains(name) || !manager.fileExists(atPath: roots.spool.appendingPathComponent(name).path) {
            offsets[name] = nil
            changed = true
        }
        if changed { try saveOffsets(offsets) }
        return report
    }

    /// One transaction: read the sessions' current rows, decide, append.
    private func drainLines(_ region: ArraySlice<UInt8>, into report: inout DrainReport) throws(CadenceError) {
        var order: [String] = []
        var folds: [String: Fold] = [:]
        var lineStart = region.startIndex
        while lineStart < region.endIndex {
            let lineEnd = region[lineStart...].firstIndex(of: 0x0A) ?? region.endIndex
            let slice = region[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            guard let line = Self.parse(slice) else {
                report.skippedMalformed += 1
                continue
            }
            switch line.event {
            case .sessionStart, .sessionEnd: break
            case .stop, .taskCompleted: report.ignored += 1
            }
            var fold = folds[line.sessionId] ?? Fold(first: line)
            if folds[line.sessionId] == nil { order.append(line.sessionId) }
            if line.date < fold.first.date { fold.first = line }
            switch line.event {
            case .sessionStart:
                if fold.start == nil || line.date < fold.start!.date { fold.start = line }
            case .sessionEnd:
                if fold.end == nil || line.date > fold.end!.date { fold.end = line }
            case .stop, .taskCompleted: break
            }
            folds[line.sessionId] = fold
        }
        let foldedOrder = order.filter { folds[$0]!.start != nil || folds[$0]!.end != nil }
        guard !foldedOrder.isEmpty else { return }

        let zone = TimeZone(identifier: config.profile.timezone) ?? .current
        let written = try store.transact { () throws(CadenceError) -> (events: Int, duplicates: Int) in
            var drafts: [EventDraft] = []
            var duplicates = 0
            for id in foldedOrder {
                let fold = folds[id]!
                let existing = try self.existing(id)
                if let payload = self.payload(for: fold, existing: existing, zone: zone) {
                    drafts.append(EventPayload.genaiSession(payload).draft(actor: .hook))
                } else {
                    duplicates += 1
                }
            }
            guard !drafts.isEmpty else { return (0, duplicates) }
            if try self.store.eventCount() == 0 {
                try self.store.ensureGenesis(
                    profile: ["timezone": .string(self.config.profile.timezone)], actor: self.genesisActor)
            }
            try self.store.append(drafts, then: { _ in })
            return (drafts.count, duplicates)
        }
        report.eventsWritten += written.events
        report.duplicates += written.duplicates
    }

    /// The payload to append, or nil when the ledger already knows everything the lines say.
    func payload(for fold: Fold, existing: GenAISession?, zone: TimeZone) -> GenAISession? {
        if var session = existing {
            guard let end = fold.end else { return nil }
            if let known = session.endedAt, let knownDate = Timestamp.parse(known), knownDate >= end.date { return nil }
            session.endedAt = end.at
            session.endReason = end.reason ?? session.endReason
            return session
        }
        let begin = fold.start ?? fold.first
        var session = GenAISession(
            sessionId: begin.sessionId, tool: Self.tool,
            day: config.dayBoundary.day(of: begin.date, in: zone).description, startedAt: begin.at,
            // privacy.projectAliases off: the folder name never reaches the ledger.
            projectAlias: config.privacy.projectAliases ? fold.start?.project ?? fold.first.project : nil,
            models: fold.start?.model.map { [$0] } ?? [])
        if let end = fold.end {
            session.endedAt = end.at
            session.endReason = end.reason
        }
        return session
    }

    private func existing(_ id: String) throws(CadenceError) -> GenAISession? {
        let row: SQLRow?
        do {
            row = try store.db.first("SELECT * FROM genai_sessions WHERE session_id = ?", [.text(id)])
        } catch {
            throw error.cadenceError
        }
        guard let row, let startedAt = row.text("started_at"), let day = row.text("day") else { return nil }
        var models: [String] = []
        if let text = row.text("models"), let parsed = try? JSONParser.parse(text).arrayValue {
            models = parsed.compactMap(\.stringValue)
        }
        return GenAISession(
            sessionId: id, tool: row.text("tool") ?? Self.tool, day: day, startedAt: startedAt,
            endedAt: row.text("ended_at"), endReason: row.text("end_reason"), projectAlias: row.text("project_alias"),
            models: models, turns: row.int("turns"))
    }

    // MARK: files and state

    static func isSpoolFile(_ name: String) -> Bool {
        name.hasPrefix("hooks-") && name.hasSuffix(".ndjson") && name.count == "hooks-2026-09-21.ndjson".count
    }

    /// A file is expired when its date (in the name) is more than 14 days before today's UTC date.
    static func isExpired(_ name: String, now: Date) -> Bool {
        let stem = name.dropFirst("hooks-".count).prefix(10)
        guard let day = LocalDate(String(stem)), let today = LocalDate(String(Timestamp.utc(now).prefix(10))) else {
            return false
        }
        return day.days(until: today) > keepDays
    }

    var stateURL: URL { roots.state.appendingPathComponent(Self.stateName) }

    /// A missing or unreadable state file is an empty one: the session rows keep a replay harmless.
    func loadOffsets() -> [String: Int] {
        guard let data = try? Data(contentsOf: stateURL),
            let object = (try? JSONParser.parse(bytes: [UInt8](data)))?.objectValue,
            let files = object["files"]?.objectValue
        else { return [:] }
        var out: [String: Int] = [:]
        for (name, value) in files {
            if let n = value.intValue, n >= 0, Self.isSpoolFile(name) { out[name] = Int(n) }
        }
        return out
    }

    func saveOffsets(_ offsets: [String: Int]) throws(CadenceError) {
        var files: [String: JSONValue] = [:]
        for (name, offset) in offsets { files[name] = .int(Int64(offset)) }
        let value: JSONValue = ["v": .int(1), "files": .object(files)]
        guard let bytes = try? CanonicalJSON.bytes(value) else { throw .io("cannot encode the spool state") }
        try PrivateFile.save(bytes + [0x0A], to: stateURL)
    }
}
