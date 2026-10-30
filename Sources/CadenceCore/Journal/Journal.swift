import Foundation

/// One entry to record. Fields override whatever the capture parser finds in `text`.
public struct LogRequest: Sendable {
    public var text: String
    public var kind: EntryKind?
    public var date: LocalDate?
    /// RFC 3339, or "HH:MM" local time on the entry's day.
    public var occurredAt: String?
    public var ticket: String?
    public var links: [Link]
    public var quantity: Int64?
    public var durationMin: Int64?
    public var note: String?
    /// Lands the entry as a proposal in the Inbox whatever its day. Without it, only an agent's entry for a
    /// past day is proposed. The entry's origin is not touched.
    public var proposed: Bool
    /// Marks the entry as dictated (`attrs.dictated`): it came from a transcript, not from a typed line.
    public var dictated: Bool

    public init(
        text: String, kind: EntryKind? = nil, date: LocalDate? = nil, occurredAt: String? = nil,
        ticket: String? = nil, links: [Link] = [], quantity: Int64? = nil, durationMin: Int64? = nil,
        note: String? = nil, proposed: Bool = false, dictated: Bool = false
    ) {
        self.text = text
        self.kind = kind
        self.date = date
        self.occurredAt = occurredAt
        self.ticket = ticket
        self.links = links
        self.quantity = quantity
        self.durationMin = durationMin
        self.note = note
        self.proposed = proposed
        self.dictated = dictated
    }
}

/// A presence span as a day shows it.
public struct PresenceRange: Sendable, Equatable {
    public var start: String
    public var end: String
    public var source: PresenceSource

    public init(start: String, end: String, source: PresenceSource) {
        self.start = start
        self.end = end
        self.source = source
    }
}

/// Everything recorded for one day. A day with no data has no invented values.
public struct DayView: Sendable, Equatable {
    public var day: Day
    public var tasks: [PlanTask]
    public var entries: [Entry]
    public var presence: [PresenceRange]

    public init(day: Day, tasks: [PlanTask], entries: [Entry], presence: [PresenceRange]) {
        self.day = day
        self.tasks = tasks
        self.entries = entries
        self.presence = presence
    }
}

public struct EntryQuery: Sendable {
    public static let maxLimit = 200

    public var from: LocalDate
    public var to: LocalDate
    public var kinds: [EntryKind]
    public var families: [Family]
    public var origins: [Origin]
    /// Empty means accepted and proposed.
    public var statuses: [EntryStatus]
    public var cursor: String?
    public var limit: Int

    public init(
        from: LocalDate, to: LocalDate, kinds: [EntryKind] = [], families: [Family] = [], origins: [Origin] = [],
        statuses: [EntryStatus] = [.accepted, .proposed], cursor: String? = nil, limit: Int = 200
    ) {
        self.from = from
        self.to = to
        self.kinds = kinds
        self.families = families
        self.origins = origins
        self.statuses = statuses
        self.cursor = cursor
        self.limit = limit
    }
}

extension Link {
    /// A link whose kind is guessed from the URL path: `/pull/` is a PR, `/browse/` a ticket.
    public static func inferred(url: String) -> Link {
        let lower = url.lowercased()
        if lower.contains("/pull/") || lower.contains("/pulls/") { return Link(kind: .pr, url: url) }
        if lower.contains("/browse/") { return Link(kind: .ticket, url: url) }
        return Link(kind: .other, url: url)
    }
}

/// The rules every writer shares: the CLI, the MCP server and the app all record and read through here.
/// Every write is one `store.append` inside one transaction, so a call either happens whole or not at all.
public final class Journal {
    public let store: SQLiteStore
    public let config: Config
    let clock: any Clock
    let ids: any IdentifierSource
    let classifier: TicketClassifier
    private let zoneValue: TimeZone

    static let maxTitle = 200
    static let maxText = 2000
    static let maxNote = 1000
    static let maxLinks = 5

    /// `actor` writes the genesis event when the ledger is empty.
    public init(
        store: SQLiteStore, config: Config, clock: any Clock, ids: any IdentifierSource, actor: Actor = .app
    ) throws(CadenceError) {
        guard let zone = TimeZone(identifier: config.profile.timezone) else {
            throw .validation("profile.timezone: unknown time zone '\(config.profile.timezone)'")
        }
        self.store = store
        self.config = config
        self.clock = clock
        self.ids = ids
        self.zoneValue = zone
        self.classifier = try TicketClassifier(rules: config.tickets)
        // Reading must not need the write lock, so only an empty ledger takes it.
        if try store.eventCount() == 0 {
            var profile: [String: JSONValue] = ["timezone": .string(config.profile.timezone)]
            if let name = config.profile.name { profile["name"] = .string(name) }
            if let role = config.profile.role { profile["role"] = .string(role) }
            try store.ensureGenesis(profile: .object(profile), actor: actor)
        }
    }

    public var zone: TimeZone { zoneValue }

    public func today() -> LocalDate {
        config.dayBoundary.day(of: clock.now(), in: zone)
    }

    // MARK: - Writes

    public func log(_ request: LogRequest, actor: Actor, origin: Origin) throws(CadenceError) -> Entry {
        var entry = try prepare(request, origin: origin)
        return try store.transact { () throws(CadenceError) -> Entry in
            entry.afterSeal = try self.isSealed(entry.day)
            entry.id = self.ids.next()
            try self.append([EventPayload.entryCreated(entry).draft(actor: actor)])
            return entry
        }
    }

    /// Several entries in one transaction: every one lands, or none does.
    public func logAll(_ requests: [LogRequest], actor: Actor, origin: Origin) throws(CadenceError) -> [Entry] {
        try store.transact { () throws(CadenceError) -> [Entry] in
            var entries: [Entry] = []
            for request in requests { entries.append(try self.log(request, actor: actor, origin: origin)) }
            return entries
        }
    }

    /// What `log` would record for `request`, checked by the same rules, with nothing written. The entry has
    /// no id (an empty string): ids are made when the event is appended.
    public func preview(_ request: LogRequest, origin: Origin) throws(CadenceError) -> Entry {
        var entry = try prepare(request, origin: origin)
        entry.afterSeal = try isSealed(entry.day)
        return entry
    }

    /// A pasted transcript as log requests, one per line or bullet, each landing as a proposal marked dictated.
    /// A line that is only a day (such as "Wed 28 Oct") sets the day for the lines after it, and a line that
    /// names a day keeps it. `date` is the day for lines that name none; without it they are for today.
    public func requests(fromTranscript text: String, date: LocalDate?) -> [LogRequest] {
        let context = CaptureContext(now: clock.now(), zone: zone, boundary: config.dayBoundary, classifier: classifier)
        return CaptureParser.splitTranscript(text, context: context).map {
            LogRequest(text: $0.text, date: $0.day ?? date, proposed: true, dictated: true)
        }
    }

    private func isSealed(_ day: String) throws(CadenceError) -> Bool {
        try rows("SELECT sealed_at FROM days WHERE date = ?", [.text(day)]).first?.text("sealed_at") != nil
    }

    /// Every rule that does not need the write lock. The entry has no id yet and is not marked after-seal.
    private func prepare(_ request: LogRequest, origin: Origin) throws(CadenceError) -> Entry {
        let text = Self.clean(request.text, limit: Self.maxText + 1)
        guard !text.isEmpty else { throw .validation("text must not be empty") }
        guard text.count <= Self.maxText else { throw .validation("text is too long (at most \(Self.maxText) characters)") }
        let now = clock.now()
        let today = self.today()
        let parsed = CaptureParser.parse(
            text, context: CaptureContext(now: now, zone: zone, boundary: config.dayBoundary, classifier: classifier))

        let title = Self.clean(parsed.title, limit: Self.maxTitle)
        guard !title.isEmpty else { throw .validation("the entry has no title") }

        // An RFC 3339 time with no stated day names its own day.
        var day = request.date ?? parsed.day
        if request.date == nil, let at = request.occurredAt, Timestamp.parseClock(at) == nil,
            let found = Timestamp.parse(at)
        {
            guard found <= now else { throw .validation("--at: \(at) is in the future") }
            day = config.dayBoundary.day(of: found, in: zone)
        }
        guard day <= today else { throw .validation("date: \(day) is in the future") }
        let dayZone = try zone(of: day)

        let kind = request.kind ?? parsed.kind
        var ticket = parsed.ticket
        if let text = request.ticket { ticket = try self.ticket(from: text) }

        let occurred: Date?
        if let at = request.occurredAt {
            occurred = try instant(at, on: day, zone: dayZone)
        } else if let found = parsed.occurredAt {
            occurred = day == parsed.day ? found : try instant(Timestamp.clockTime(found, in: zone), on: day, zone: dayZone)
        } else {
            occurred = day == today ? now : nil
        }

        var quantity = parsed.quantity
        if let n = request.quantity {
            guard (1...50).contains(n) else { throw .validation("quantity: must be between 1 and 50") }
            quantity = n
        }

        let durationS: Int64?
        if let minutes = request.durationMin {
            guard (1...720).contains(minutes) else { throw .validation("duration: must be between 1 and 720 minutes") }
            durationS = minutes * 60
        } else {
            durationS = parsed.durationS
        }

        var links = parsed.links
        for link in request.links {
            guard link.url.lowercased().hasPrefix("https://"), link.url.count > "https://".count,
                !link.url.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } })
            else { throw .validation("link: only https links are accepted") }
            if !links.contains(link) { links.append(link) }
        }
        guard links.count <= Self.maxLinks else { throw .validation("links: at most \(Self.maxLinks) per entry") }

        var attrs: [String: JSONValue] = [:]
        if let note = request.note {
            let cleaned = Self.clean(note, limit: Self.maxNote + 1)
            guard cleaned.count <= Self.maxNote else { throw .validation("note: at most \(Self.maxNote) characters") }
            if !cleaned.isEmpty { attrs["note"] = .string(cleaned) }
        }

        let isAgent = origin == .agent
        if request.dictated { attrs["dictated"] = .bool(true) }
        return Entry(
            id: "", day: day.description, kind: kind,
            family: EntryKind.family(for: kind, ticketClass: ticket?.class), title: title,
            occurredAt: occurred.map { Timestamp.local($0, in: dayZone) }, durationS: durationS,
            quantity: quantity, ticket: ticket, links: links, tags: parsed.tags, attrs: attrs, origin: origin,
            status: request.proposed || (isAgent && day < today) ? .proposed : .accepted, backfilled: day < today,
            afterSeal: false, export: kind == .note ? .digest : .include)
    }

    public func planAdd(
        title: String, day: LocalDate?, estimateMin: Int64?, origin: PlanOrigin, actor: Actor
    ) throws(CadenceError) -> PlanTask {
        let cleaned = Self.clean(title, limit: Self.maxTitle)
        guard !cleaned.isEmpty else { throw .validation("title must not be empty") }
        if let estimateMin, !(1...1440).contains(estimateMin) {
            throw .validation("estimate: must be between 1 and 1440 minutes")
        }
        let day = day ?? today()
        let ticket = classifier.firstTicket(in: cleaned).map {
            Ticket(key: $0.key, class: $0.selfInitiated ? .selfInitiated : .assigned)
        }
        let plannedAt = Timestamp.local(clock.now(), in: zone)
        return try store.transact { () throws(CadenceError) -> PlanTask in
            let highest = try self.rows(
                "SELECT COALESCE(MAX(position), 0) AS highest FROM plan_tasks WHERE day = ?", [.text(day.description)]
            ).first?.int("highest") ?? 0
            let task = PlanTask(
                id: self.ids.next(), day: day.description, position: highest + 1, title: cleaned, ticket: ticket,
                estimateMin: estimateMin, origin: origin, plannedAt: plannedAt)
            try self.append([EventPayload.planAdded(task).draft(actor: actor)])
            return task
        }
    }

    public func planResolve(
        taskID: String, status: TaskStatus, reason: String?, note: String?, links: [String], actor: Actor
    ) throws(CadenceError) -> PlanTask {
        guard status == .done || status == .slipped || status == .dropped else {
            throw .validation("status: a task is resolved as done, slipped or dropped")
        }
        let reason = reason.map { Self.clean($0, limit: 100) }.flatMap { $0.isEmpty ? nil : $0 }
        if status == .slipped, reason == nil { throw .validation("a slipped task needs a reason") }
        let note = note.map { Self.clean($0, limit: Self.maxNote) }.flatMap { $0.isEmpty ? nil : $0 }
        return try store.transact { () throws(CadenceError) -> PlanTask in
            guard let current = try self.rows("SELECT status FROM plan_tasks WHERE id = ?", [.text(taskID)]).first else {
                throw .notFound("no plan task with id \(taskID)")
            }
            if current.text("status") == TaskStatus.moved.rawValue {
                let next = try self.rows("SELECT id FROM plan_tasks WHERE carried_from = ?", [.text(taskID)]).first?.text("id")
                throw .validation(
                    "task \(taskID) was carried to a later day" + (next.map { " as \($0); resolve that task instead" } ?? ""))
            }
            for link in links where try self.rows("SELECT id FROM entries WHERE id = ?", [.text(link)]).first == nil {
                throw .notFound("no entry with id \(link)")
            }
            try self.append([
                EventPayload.planResolved(PlanResolved(status: status, reason: reason, reasonNote: note, links: links))
                    .draft(actor: actor, id: taskID)
            ])
            return try self.task(taskID)
        }
    }

    /// Changes an open task's title or estimate. A new title brings its ticket with it, as when the task was added.
    /// A task that is already resolved or moved is not edited, and a change that changes nothing writes nothing.
    public func planEdit(taskID: String, title: String?, estimateMin: Int64?, actor: Actor) throws(CadenceError) -> PlanTask {
        guard title != nil || estimateMin != nil else { throw .validation("nothing to change: give a title or an estimate") }
        let cleaned = title.map { Self.clean($0, limit: Self.maxTitle) }
        if let cleaned, cleaned.isEmpty { throw .validation("title must not be empty") }
        if let estimateMin, !(1...1440).contains(estimateMin) {
            throw .validation("estimate: must be between 1 and 1440 minutes")
        }
        return try store.transact { () throws(CadenceError) -> PlanTask in
            let current = try self.task(taskID)
            guard current.status == .open else {
                throw .validation("task \(taskID) is \(current.status.rawValue); only an open task can be edited")
            }
            var fields: [String: Change] = [:]
            if let cleaned, cleaned != current.title {
                fields["title"] = Change(old: .string(current.title), new: .string(cleaned))
                let ticket = self.classifier.firstTicket(in: cleaned).map {
                    Ticket(key: $0.key, class: $0.selfInitiated ? .selfInitiated : .assigned)
                }
                if ticket != current.ticket {
                    fields["ticket"] = Change(old: current.ticket?.json ?? .null, new: ticket?.json ?? .null)
                }
            }
            if let estimateMin, estimateMin != current.estimateMin {
                fields["estimate_min"] = Change(old: current.estimateMin.jsonValue, new: .int(estimateMin))
            }
            guard !fields.isEmpty else { return current }
            try self.append([EventPayload.planUpdated(Changes(fields: fields)).draft(actor: actor, id: taskID)])
            return try self.task(taskID)
        }
    }

    public func startDay(_ day: LocalDate?, at: String?, actor: Actor) throws(CadenceError) {
        try markDay(day, at: at, actor: actor) { mark in .dayStarted(mark) }
    }

    public func endDay(_ day: LocalDate?, at: String?, actor: Actor) throws(CadenceError) {
        try markDay(day, at: at, actor: actor) { mark in .dayEnded(mark) }
    }

    private func markDay(
        _ day: LocalDate?, at: String?, actor: Actor, payload: (DayMark) -> EventPayload
    ) throws(CadenceError) {
        let today = self.today()
        let now = clock.now()
        var day = day
        if day == nil, let at, Timestamp.parseClock(at) == nil, let found = Timestamp.parse(at) {
            guard found <= now else { throw .validation("--at: \(at) is in the future") }
            day = config.dayBoundary.day(of: found, in: zone)
        }
        let target = day ?? today
        guard target <= today else { throw .validation("date: \(target) is in the future") }
        let dayZone = try zone(of: target)
        let instant: Date
        if let at {
            instant = try self.instant(at, on: target, zone: dayZone)
        } else {
            guard target == today else { throw .validation("a time is needed for a day that is not today") }
            instant = now
        }
        let mark = DayMark(
            day: target.description, tz: dayZone.identifier, at: Timestamp.local(instant, in: dayZone),
            source: at != nil || actor != .app ? .manual : .input)
        try store.transact { () throws(CadenceError) -> Void in
            try self.append([payload(mark).draft(actor: actor)])
        }
    }

    public func declare(_ day: LocalDate, kind: DayKind, label: String?, actor: Actor) throws(CadenceError) {
        let label = label.map { Self.clean($0, limit: 100) }.flatMap { $0.isEmpty ? nil : $0 }
        let declared = DayDeclared(day: day.description, tz: try zone(of: day).identifier, kind: kind, label: label)
        try store.transact { () throws(CadenceError) -> Void in
            try self.append([EventPayload.dayDeclared(declared).draft(actor: actor)])
        }
    }

    /// Records the ticket rules in force as `config.classifier` (digests only, never the pattern text), but only
    /// when they differ from the last recorded rules, or from the defaults when none was recorded. Returns
    /// whether an event was written.
    @discardableResult
    public func recordClassifier(actor: Actor) throws(CadenceError) -> Bool {
        let hasher = SHA256Hasher()
        func digests(_ rules: TicketRules) -> [String] {
            [rules.pattern, rules.selfInitiated].map { "sha256:" + hasher.sha256Hex(Array($0.utf8)) }
        }
        let current = digests(config.tickets)
        return try store.transact { () throws(CadenceError) -> Bool in
            let last = try self.store.readEvents(
                "SELECT * FROM events WHERE type = 'config.classifier' ORDER BY seq DESC LIMIT 1", []
            ).first
            var recorded = digests(TicketRules())
            if let last, case .configClassifier(let found)? = try? EventPayload(type: last.type, data: last.data) {
                recorded = found.patterns
            }
            guard recorded != current else { return false }
            try self.append([EventPayload.configClassifier(ConfigClassifier(patterns: current)).draft(actor: actor)])
            return true
        }
    }

    /// Inbox moves: proposed to accepted or dismissed, accepted to dismissed, dismissed to accepted.
    /// The entry's origin never changes.
    public func setStatus(entryID: String, to: EntryStatus, note: String?, actor: Actor) throws(CadenceError) -> Entry {
        let note = note.map { Self.clean($0, limit: Self.maxNote) }.flatMap { $0.isEmpty ? nil : $0 }
        return try store.transact { () throws(CadenceError) -> Entry in
            let current = try self.entry(entryID)
            let allowed: Set<EntryStatus>
            switch current.status {
            case .proposed: allowed = [.accepted, .dismissed]
            case .accepted: allowed = [.dismissed]
            case .dismissed: allowed = [.accepted]
            case .deleted: allowed = []
            }
            guard allowed.contains(to) else {
                throw .validation("an entry that is \(current.status.rawValue) cannot become \(to.rawValue)")
            }
            try self.append([
                EventPayload.entryStatus(EntryStatusChange(from: current.status, to: to, note: note))
                    .draft(actor: actor, id: entryID)
            ])
            return try self.entry(entryID)
        }
    }

    // MARK: - Reads

    /// A day with no row is a workday or a weekend by the configured workdays, with no data.
    public func dayView(_ day: LocalDate) throws(CadenceError) -> DayView {
        let key = SQLValue.text(day.description)
        var view: Day
        if let row = try rows("SELECT * FROM days WHERE date = ?", [key]).first {
            view = try Readers.day(row)
        } else {
            view = Day(date: day.description, tz: zone.identifier)
        }
        view.kind = DayRules(config: config).kind(of: day, declared: try store.declaredKind(of: day))
        let tasks = try rows("SELECT * FROM plan_tasks WHERE day = ? ORDER BY position, created_seq", [key])
            .map { (row) throws(CadenceError) -> PlanTask in try Readers.task(row) }
        let entries = try rows(
            """
            SELECT * FROM entries WHERE day = ? AND status IN ('accepted', 'proposed')
            ORDER BY COALESCE(occurred_at, ''), created_seq
            """, [key]
        ).map { (row) throws(CadenceError) -> Entry in try Readers.entry(row) }
        let presence = try rows("SELECT * FROM presence_spans WHERE day = ? ORDER BY start_at, id", [key]).map {
            row -> PresenceRange in
            PresenceRange(
                start: row.text("start_at") ?? "", end: row.text("end_at") ?? "",
                source: PresenceSource(rawValue: row.text("source") ?? "") ?? .manual)
        }
        return DayView(day: view, tasks: tasks, entries: entries, presence: presence)
    }

    /// Entries by day, then occurred time (missing times first), then creation. The cursor is the base64 of the
    /// last entry's creation sequence; the next page starts after that entry's place in the order.
    public func query(_ q: EntryQuery) throws(CadenceError) -> (entries: [Entry], next: String?) {
        guard q.from <= q.to else { throw .validation("from must not be after to") }
        let limit = min(max(q.limit, 1), EntryQuery.maxLimit)
        var sql = "SELECT * FROM entries WHERE day >= ? AND day <= ?"
        var args: [SQLValue] = [.text(q.from.description), .text(q.to.description)]
        func restrict(_ column: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            sql += " AND \(column) IN (" + values.map { _ in "?" }.joined(separator: ", ") + ")"
            args += values.map { SQLValue.text($0) }
        }
        restrict("kind", q.kinds.map(\.rawValue))
        restrict("family", q.families.map(\.rawValue))
        restrict("origin", q.origins.map(\.rawValue))
        restrict("status", (q.statuses.isEmpty ? [.accepted, .proposed] : q.statuses).map(\.rawValue))
        if let cursor = q.cursor {
            guard let data = Data(base64Encoded: cursor), let text = String(data: data, encoding: .utf8),
                let seq = Int64(text),
                try rows("SELECT 1 FROM entries WHERE created_seq = ?", [.int(seq)]).first != nil
            else { throw .validation("cursor is not valid") }
            sql += """
                 AND (day, COALESCE(occurred_at, ''), created_seq) >
                (SELECT day, COALESCE(occurred_at, ''), created_seq FROM entries WHERE created_seq = ?)
                """
            args.append(.int(seq))
        }
        sql += " ORDER BY day, COALESCE(occurred_at, ''), created_seq LIMIT ?"
        args.append(.int(Int64(limit + 1)))
        var found = try rows(sql, args).map { (row) throws(CadenceError) -> Entry in try Readers.entry(row) }
        var next: String?
        if found.count > limit {
            found.removeLast()
            if let last = try rows("SELECT created_seq FROM entries WHERE id = ?", [.text(found[found.count - 1].id)]).first?
                .int("created_seq")
            {
                next = Data(String(last).utf8).base64EncodedString()
            }
        }
        return (found, next)
    }

    /// Proposals waiting for a decision, oldest first.
    public func inbox() throws(CadenceError) -> [Entry] {
        try rows("SELECT * FROM entries WHERE status = 'proposed' ORDER BY day, COALESCE(occurred_at, ''), created_seq")
            .map { (row) throws(CadenceError) -> Entry in try Readers.entry(row) }
    }

    public func entry(_ id: String) throws(CadenceError) -> Entry {
        guard let row = try rows("SELECT * FROM entries WHERE id = ?", [.text(id)]).first else {
            throw .notFound("no entry with id \(id)")
        }
        return try Readers.entry(row)
    }

    public func task(_ id: String) throws(CadenceError) -> PlanTask {
        guard let row = try rows("SELECT * FROM plan_tasks WHERE id = ?", [.text(id)]).first else {
            throw .notFound("no plan task with id \(id)")
        }
        return try Readers.task(row)
    }

    /// Every event for a subject such as "entry:<id>", "task:<id>" or "day:2026-10-29", in order.
    public func history(subject: String) throws(CadenceError) -> [Event] {
        try store.events(subject: subject)
    }

    // MARK: - Helpers

    func rows(_ sql: String, _ parameters: [SQLValue] = []) throws(CadenceError) -> [SQLRow] {
        do {
            return try store.db.query(sql, parameters)
        } catch {
            throw error.cadenceError
        }
    }

    func append(_ drafts: [EventDraft]) throws(CadenceError) {
        _ = try store.append(drafts, then: { _ in })
    }

    private func ticket(from text: String) throws(CadenceError) -> Ticket {
        guard let match = classifier.firstTicket(in: text) else { throw .validation("ticket: no ticket key found") }
        return Ticket(key: match.key, class: match.selfInitiated ? .selfInitiated : .assigned)
    }

    /// The zone a day was recorded in: the one its `days` row carries, otherwise the profile zone.
    func zone(of day: LocalDate) throws(CadenceError) -> TimeZone {
        try rows("SELECT tz FROM days WHERE date = ?", [.text(day.description)]).first?.text("tz")
            .flatMap { TimeZone(identifier: $0) } ?? zoneValue
    }

    /// "HH:MM" on `day` in `zone` (a time before the day boundary falls on the next calendar date), or an
    /// RFC 3339 instant. The instant must not be in the future and must belong to `day`.
    private func instant(_ text: String, on day: LocalDate, zone: TimeZone) throws(CadenceError) -> Date {
        let found: Date
        if let (hour, minute) = Timestamp.parseClock(text) {
            let before = hour * 60 + minute < config.dayBoundary.hour * 60 + config.dayBoundary.minute
            found = Timestamp.resolve(before ? day.adding(days: 1) : day, hour: hour, minute: minute, in: zone)
        } else if let date = Timestamp.parse(text) {
            found = date
        } else {
            throw .validation("time must be HH:MM or an RFC 3339 time")
        }
        guard found <= clock.now() else { throw .validation("--at: \(text) is in the future") }
        guard config.dayBoundary.day(of: found, in: zone) == day else {
            throw .validation("--at: \(text) is not on \(day)")
        }
        return found
    }

    /// Unicode bidirectional format characters, which can make text read differently from how it is stored.
    private static func isBidiFormat(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C: true
        default: false
        }
    }

    /// Control characters and bidi format characters out, whitespace collapsed, cut to `limit` characters.
    static func clean(_ raw: String, limit: Int) -> String {
        var spaced = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "\n" || scalar == "\t" || scalar == "\r" {
                spaced.append(" ")
            } else if scalar.properties.generalCategory != .control, !Self.isBidiFormat(scalar) {
                spaced.append(scalar)
            }
        }
        let collapsed = String(spaced).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces)
    }
}
