import Foundation

/// A task that was moved to the next workday by a seal.
public struct CarriedTask: Sendable, Equatable {
    /// The id of the task on the sealed day, now `moved`.
    public var from: String
    /// The new task on the next workday.
    public var task: PlanTask

    public init(from: String, task: PlanTask) {
        self.from = from
        self.task = task
    }
}

/// What a wrap-up did (docs/SPEC.md sections 3 and 4.5).
public struct SealResult: Sendable, Equatable {
    public var day: LocalDate
    /// RFC 3339 in the profile zone.
    public var sealedAt: String
    /// Whether the seal counts for the streak. Always true: any seal counts, whenever it was made. Kept so the
    /// `counts_for_streak` field of the JSON output stays.
    public var counts: Bool
    public var carried: [CarriedTask]
    /// Entries per family (non-zero families only) plus `entries`, as recorded in `day.sealed`.
    public var entryCounts: [String: Int64]
    public var plan: PlanCounts
    public var streak: Streak

    public var json: JSONValue {
        var counts: [String: JSONValue] = [:]
        for (key, value) in entryCounts { counts[key] = .int(value) }
        return [
            "day": .string(day.description), "sealed_at": .string(sealedAt), "counts_for_streak": .bool(self.counts),
            "carried": .array(carried.map { ["from": .string($0.from), "task": $0.task.json] }),
            "counts": .object(counts), "plan": plan.json, "streak": streak.json,
        ]
    }
}

/// What a reopening did (docs/SPEC.md section 3).
public struct ReopenResult: Sendable, Equatable {
    public var day: LocalDate
    /// RFC 3339 in the profile zone.
    public var reopenedAt: String
    /// The seal this undid, RFC 3339 in the profile zone.
    public var sealedAt: String
    /// The streak with the day unsealed.
    public var streak: Streak

    public var json: JSONValue {
        [
            "day": .string(day.description), "reopened_at": .string(reopenedAt), "sealed_at": .string(sealedAt),
            "streak": streak.json,
        ]
    }
}

/// One seal or reopening of a day, as the day's history shows it: "Sealed 13:15, reopened 14:02, sealed again 15:30".
public struct DayHistoryItem: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case sealed
        case reopened
    }

    public var kind: Kind
    /// When the event was recorded. Format it in the day's own zone.
    public var at: Date
    public var actor: Actor
    /// The ledger position of the event.
    public var seq: Int64
}

/// The stand-up text a wrap-up copies, and the witness code on its last line.
public struct StandupText: Sendable, Equatable {
    public var text: String
    public var code: String
}

extension Journal {
    // MARK: - Seal

    /// Wraps up a day: carries every open task to the next workday, then records `day.sealed`, all in one
    /// transaction. Today and any past day can be sealed, and every seal counts for the streak, whenever it is made.
    /// A day that was reopened reads as unsealed, so this is also how it is sealed again.
    public func seal(_ day: LocalDate?, actor: Actor) throws(CadenceError) -> SealResult {
        let today = self.today()
        let day = day ?? today
        guard day <= today else { throw .validation("date: \(day) is in the future") }
        let rules = DayRules(config: config)
        let plannedAt = Timestamp.local(clock.now(), in: zone)
        let key = SQLValue.text(day.description)

        struct Sealed {
            var at: String
            var carried: [CarriedTask]
            var counts: [String: Int64]
            var plan: PlanCounts
        }

        let sealed = try store.transact { () throws(CadenceError) -> Sealed in
            let row = try self.rows("SELECT tz, sealed_at FROM days WHERE date = ?", [key]).first
            if let at = row?.text("sealed_at") {
                let time = Timestamp.parse(at).map { Timestamp.clockTime($0, in: self.zone) } ?? at
                throw .validation("\(day) is already wrapped up at \(time)")
            }
            let dayZone = row?.text("tz").flatMap { TimeZone(identifier: $0) } ?? self.zone

            // Carry-over: every open task moves to the next workday, positions appended after what is there.
            let open = try self.rows(
                "SELECT * FROM plan_tasks WHERE day = ? AND status = 'open' ORDER BY position, created_seq", [key]
            ).map { (row) throws(CadenceError) -> PlanTask in try Readers.task(row) }
            var carried: [CarriedTask] = []
            var drafts: [EventDraft] = []
            if !open.isEmpty {
                let target = try self.carryTarget(after: day, today: today, rules: rules)
                var position = try self.rows(
                    "SELECT COALESCE(MAX(position), 0) AS highest FROM plan_tasks WHERE day = ?",
                    [.text(target.description)]
                ).first?.int("highest") ?? 0
                for old in open {
                    position += 1
                    let moved = PlanTask(
                        id: self.ids.next(), day: target.description, position: position, title: old.title,
                        ticket: old.ticket, estimateMin: old.estimateMin, origin: .carried, carriedFrom: old.id,
                        plannedAt: plannedAt)
                    drafts.append(EventPayload.planResolved(PlanResolved(status: .moved)).draft(actor: actor, id: old.id))
                    drafts.append(EventPayload.planAdded(moved).draft(actor: actor))
                    carried.append(CarriedTask(from: old.id, task: moved))
                }
                _ = try self.store.append(drafts, then: { _ in })
            }

            var counts: [String: Int64] = [:]
            var total: Int64 = 0
            for row in try self.rows(
                "SELECT family, COUNT(*) AS n FROM entries WHERE day = ? AND status = 'accepted' GROUP BY family", [key])
            {
                guard let family = row.text("family"), let n = row.int("n"), n > 0 else { continue }
                counts[family] = n
                total += n
            }
            if total > 0 { counts["entries"] = total }

            var tally: [String: Int64] = [:]
            for row in try self.rows("SELECT status, COUNT(*) AS n FROM plan_tasks WHERE day = ? GROUP BY status", [key]) {
                if let status = row.text("status"), let n = row.int("n") { tally[status] = n }
            }
            let plan = PlanCounts(
                done: tally["done"] ?? 0, slipped: tally["slipped"] ?? 0, dropped: tally["dropped"] ?? 0,
                moved: tally["moved"] ?? 0, open: tally["open"] ?? 0)

            // The head is read after the carry events and the seal is its own append, so head == prev.
            let head: Event?
            do { head = try self.store.head() } catch { throw (error as? CadenceError) ?? .io(String(describing: error)) }
            guard let head else { throw .integrity("the ledger is empty; write ledger.genesis first") }
            let payload = DaySealed(day: day.description, tz: dayZone.identifier, counts: counts, plan: plan, head: head.hash)
            let events = try self.store.append([EventPayload.daySealed(payload).draft(actor: actor)], then: { _ in })
            guard let event = events.first else { throw .integrity("the seal did not read back") }
            return Sealed(at: event.at, carried: carried, counts: counts, plan: plan)
        }

        let sealedDate = Timestamp.parse(sealed.at) ?? clock.now()
        return SealResult(
            day: day, sealedAt: Timestamp.local(sealedDate, in: zone),
            counts: true, carried: sealed.carried, entryCounts: sealed.counts, plan: sealed.plan,
            streak: try streak(asOf: nil))
    }

    // MARK: - Reopen

    /// Opens a sealed day again so it can be changed and sealed again (docs/SPEC.md section 3). Any day can be
    /// reopened at any time, however old. The ledger only grows: this appends `day.reopened` and removes nothing, so
    /// every earlier seal stays in the day's history. The day reads as unsealed from here, which makes `seal` the way
    /// to seal it again. Only the app and the CLI reopen a day; the MCP server has no tool for it.
    public func reopen(day: LocalDate?, actor: Actor) throws(CadenceError) -> ReopenResult {
        guard actor == .app || actor == .cli else {
            throw .validation("only you can reopen a day; use the app or cadence day reopen")
        }
        let today = self.today()
        let day = day ?? today
        guard day <= today else { throw .validation("date: \(day) is in the future") }
        let key = SQLValue.text(day.description)

        let (sealedAt, reopenedAt) = try store.transact { () throws(CadenceError) -> (String, String) in
            guard let sealedAt = try self.rows("SELECT sealed_at FROM days WHERE date = ?", [key]).first?.text("sealed_at") else {
                throw .validation("\(day) is not wrapped up, so there is nothing to reopen")
            }
            let events = try self.store.append(
                [EventPayload.dayReopened(DayReopened(day: day.description)).draft(actor: actor)], then: { _ in })
            guard let event = events.first else { throw .integrity("the reopening did not read back") }
            return (sealedAt, event.at)
        }

        func local(_ text: String) -> String { Timestamp.parse(text).map { Timestamp.local($0, in: zone) } ?? text }
        return ReopenResult(day: day, reopenedAt: local(reopenedAt), sealedAt: local(sealedAt), streak: try streak(asOf: nil))
    }

    /// The seals and reopenings of `date`, oldest first, read from the ledger. An event the projection ignored is not
    /// history: a seal while the day was already sealed, or a reopening of a day that was not sealed.
    public func dayHistory(_ date: LocalDate) throws(CadenceError) -> [DayHistoryItem] {
        var items: [DayHistoryItem] = []
        var sealed = false
        for event in try store.events(subject: "day:\(date)") {
            let kind: DayHistoryItem.Kind
            switch event.type {
            case "day.sealed" where !sealed: kind = .sealed
            case "day.reopened" where sealed: kind = .reopened
            default: continue
            }
            guard let at = Timestamp.parse(event.at) else { continue }
            sealed = kind == .sealed
            items.append(DayHistoryItem(kind: kind, at: at, actor: event.actor, seq: event.seq))
        }
        return items
    }

    /// When the seal that stood at `reference` was made, read from the day's events: nil when the day was not sealed
    /// then, or had been reopened since its last seal. The same reading as `dayHistory`, stopped at `reference`.
    func sealInForce(_ date: LocalDate, at reference: Date) throws(CadenceError) -> Date? {
        guard let last = try dayHistory(date).last(where: { $0.at <= reference }), last.kind == .sealed else { return nil }
        return last.at
    }

    // MARK: - Streak

    /// Consecutive workdays that are sealed, as of `asOf` (default today). One query for the days, one for
    /// the declarations, then a pure walk (`DayRules.streak`). A day counts when it was sealed at the end of `asOf`.
    /// For a day that was never reopened that is its seal, if made by then. A day that was reopened is read from its
    /// events instead (`sealInForce`), so one sealed on the 1st and sealed again on the 20th still counts as of the
    /// 5th, and one reopened on the 8th reads as open from then until it is sealed again.
    public func streak(asOf: LocalDate? = nil) throws(CadenceError) -> Streak {
        let today = self.today()
        let asOf = asOf ?? today
        guard asOf <= today else { throw .validation("date: \(asOf) is in the future") }
        // For a past day the reference instant is the end of that day, and later seals do not exist yet.
        let reference =
            asOf == today
            ? clock.now() : Timestamp.resolve(asOf.adding(days: 1), hour: 0, minute: 0, in: zone).addingTimeInterval(-0.001)
        // The walk starts on the day the ledger began, as summary and proof do; earlier days never count.
        guard let first = try ledgerStart() else { return Streak() }
        var reopened = Set<String>()
        for row in try rows("SELECT DISTINCT subject FROM events WHERE type = 'day.reopened'") {
            if let subject = row.text("subject"), subject.hasPrefix("day:") { reopened.insert(String(subject.dropFirst(4))) }
        }
        var sealed: DayRules.SealedDays = [:]
        for row in try rows("SELECT date, tz, sealed_at FROM days ORDER BY date") {
            guard let key = row.text("date"), let date = LocalDate(key), date >= first else { continue }
            let at: Date?
            if reopened.contains(key) {
                at = try sealInForce(date, at: reference)
            } else {
                at = row.text("sealed_at").flatMap { Timestamp.parse($0) }.flatMap { $0 <= reference ? $0 : nil }
            }
            if let at { sealed[date] = (at, row.text("tz").flatMap { TimeZone(identifier: $0) } ?? zone) }
        }
        return DayRules(config: config).streak(
            sealed: sealed, declared: try declaredKinds(), first: first, asOf: asOf, now: reference, zone: zone)
    }

    /// The day the ledger began: the local day of `ledger.genesis` in the profile zone.
    func ledgerStart() throws(CadenceError) -> LocalDate? {
        let found = try store.readEvents("SELECT * FROM events WHERE type = 'ledger.genesis' ORDER BY seq LIMIT 1", [])
        guard let genesis = found.first, let at = Timestamp.parse(genesis.at) else { return nil }
        return config.dayBoundary.day(of: at, in: zone)
    }

    /// Where a seal's open tasks go: the first workday on or after the later of the day after `day` and today
    /// that is not sealed yet. Never a past day and never a sealed one, which would strand the tasks.
    func carryTarget(after day: LocalDate, today: LocalDate, rules: DayRules) throws(CadenceError) -> LocalDate {
        let declared = try declaredKinds()
        var candidate = max(day.adding(days: 1), today)
        for _ in 0..<366 {
            if rules.kind(of: candidate, declared: declared[candidate]) == .workday {
                let row = try rows("SELECT sealed_at FROM days WHERE date = ?", [.text(candidate.description)]).first
                if row?.text("sealed_at") == nil { return candidate }
            }
            candidate = candidate.adding(days: 1)
        }
        return rules.nextWorkday(after: max(day, today.adding(days: -1)), declared: declared)
    }

    /// The latest declared kind of every declared day, in one query.
    func declaredKinds() throws(CadenceError) -> [LocalDate: DayKind] {
        var kinds: [LocalDate: DayKind] = [:]
        for event in try store.readEvents("SELECT * FROM events WHERE type = 'day.declared' ORDER BY seq", []) {
            if case .dayDeclared(let declared)? = try? EventPayload(type: event.type, data: event.data),
                let date = LocalDate(declared.day)
            {
                kinds[date] = declared.kind
            }
        }
        return kinds
    }

    // MARK: - Stand-up

    static let standUpFamilies = "('delivery', 'review', 'initiative', 'ownership', 'leadership')"

    /// The stand-up text for `day` (default today), ending in a witness code. Appends a `witness.checkpoint`
    /// unless the head already is one for this day.
    public func standup(_ day: LocalDate?, actor: Actor = .cli) throws(CadenceError) -> StandupText {
        let day = day ?? today()
        let body = try standupDraft(for: day).lines()
        let witness = try store.witness(day: day, actor: actor)
        return StandupText(text: (body + [witness.line]).joined(separator: "\n"), code: witness.code)
    }

    /// The stand-up text for `day` (default today) without a witness code. Reads only: nothing is appended,
    /// so a caller that must not write to the ledger can still show the text.
    public func standupText(_ day: LocalDate?) throws(CadenceError) -> String {
        try standupDraft(for: day ?? today()).lines().joined(separator: "\n")
    }

    /// The stand-up in parts, so a caller with a size limit can show fewer bullets and still end in whole lines.
    public func standupDraft(_ day: LocalDate?) throws(CadenceError) -> StandupDraft {
        try standupDraft(for: day ?? today())
    }

    private func standupDraft(for day: LocalDate) throws(CadenceError) -> StandupDraft {
        let today = self.today()
        guard day <= today else { throw .validation("date: \(day) is in the future") }
        let key = SQLValue.text(day.description)

        func bullet(_ title: String, _ ticket: Ticket?) -> String {
            "\u{2022} " + title + Self.ticketSuffix(ticket, in: title)
        }

        let entries = try rows(
            """
            SELECT * FROM entries WHERE day = ? AND status = 'accepted' AND family IN \(Self.standUpFamilies)
            ORDER BY COALESCE(occurred_at, ''), created_seq
            """, [key]
        ).map { (row) throws(CadenceError) -> Entry in try Readers.entry(row) }
        let done = entries.map { bullet($0.title, $0.ticket) }

        // The same definitions as summary and proof: rows, not quantities.
        let reviews = try rows(
            "SELECT COUNT(*) AS n FROM entries WHERE day = ? AND status = 'accepted' AND kind = 'review.given'",
            [key]
        ).first?.int("n") ?? 0
        let merged = try rows(
            """
            SELECT COUNT(*) AS n FROM entries
            WHERE day = ? AND status = 'accepted' AND kind = 'pr.merged' AND origin = 'collected' AND source = 'github'
            """,
            [key]
        ).first?.int("n") ?? 0
        let sessions = try rows(
            "SELECT COUNT(*) AS n FROM genai_sessions WHERE day = ? AND tool LIKE 'claude%'", [key]
        ).first?.int("n") ?? 0
        var parts: [String] = []
        if reviews > 0 { parts.append("Reviews \(reviews)") }
        if merged > 0 { parts.append("PRs merged \(merged)") }
        if sessions > 0 { parts.append("Claude Code \(sessions) session\(sessions == 1 ? "" : "s")") }
        var countLines: [String] = []
        if !parts.isEmpty { countLines.append(parts.joined(separator: " \u{00B7} ")) }
        if config.genai.standupLine, let line = try aiStandupLine(day: key, sessions: Int(sessions)) { countLines.append(line) }
        // The AI line of section 11.2 rides with the counts, so the size fitting keeps or drops them together.
        let counts = countLines.isEmpty ? nil : countLines.joined(separator: "\n")

        // The same day a seal carries open tasks to, so Next shows where they went.
        let nextDay = try carryTarget(after: day, today: self.today(), rules: DayRules(config: config))
        let tasks = try rows(
            "SELECT * FROM plan_tasks WHERE day = ? AND status = 'open' ORDER BY position, created_seq",
            [.text(nextDay.description)]
        ).map { (row) throws(CadenceError) -> PlanTask in try Readers.task(row) }
        var next: [String] = []
        for task in tasks {
            var line = bullet(task.title, task.ticket)
            if let from = task.carriedFrom, let source = try? self.task(from), source.status == .slipped,
                let reason = source.reason
            {
                line += " (slipped: \(reason))"
            }
            next.append(line)
        }
        return StandupDraft(heading: "*\(Self.standUpDate(day))*", done: done, counts: counts, next: next)
    }

    /// The optional line of docs/SPEC.md section 11.2, "AI: 4 sessions · 2 of 3 merges AI-assisted". A part with no
    /// record is left out, so the line is nil rather than "AI: 0 sessions". The merges are the same rows as the
    /// counts line above; those with no recorded AI marker are left out of the "of".
    private func aiStandupLine(day: SQLValue, sessions: Int) throws(CadenceError) -> String? {
        var parts: [String] = []
        if sessions > 0 { parts.append("\(sessions) session\(sessions == 1 ? "" : "s")") }
        let markers = try rows(
            """
            SELECT attrs FROM entries
            WHERE day = ? AND status = 'accepted' AND kind = 'pr.merged' AND origin = 'collected' AND source = 'github'
            ORDER BY created_seq
            """, [day]
        ).map { GenAIMetrics.marker(inAttrs: $0.text("attrs")) }
        if let assisted = GenAIMetrics.assistedMerges(markers), assisted.share.of > 0 {
            parts.append("\(assisted.share.value) of \(assisted.share.of) merge\(assisted.share.of == 1 ? "" : "s") AI-assisted")
        }
        return parts.isEmpty ? nil : "AI: " + parts.joined(separator: " \u{00B7} ")
    }

    private static func ticketSuffix(_ ticket: Ticket?, in title: String) -> String {
        guard let ticket, !title.contains(ticket.key) else { return "" }
        return " (\(ticket.key))"
    }

    /// "Thu 29 Oct".
    public static func standUpDate(_ day: LocalDate) -> String {
        let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let parts = day.description.split(separator: "-").compactMap { Int($0) }
        let weekday = Weekday.allCases.firstIndex(of: day.weekday) ?? 0
        return "\(weekdays[weekday]) \(parts[2]) \(months[parts[1] - 1])"
    }
}

/// A stand-up before it is joined into text (docs/SPEC.md section 4.5): the bullets of Done and Next, whole.
public struct StandupDraft: Sendable, Equatable {
    public var heading: String
    /// Done bullets, each with its leading bullet mark.
    public var done: [String]
    /// The line of counts, such as "Reviews 2, PRs merged 1" with a middle dot between them, when there is anything to
    /// count, followed by the optional AI line on its own line.
    public var counts: String?
    public var next: [String]

    /// The most bullets either list holds.
    public var longest: Int { max(done.count, next.count) }

    /// The text lines. With `maxBullets`, a list longer than that shows that many bullets and then one line saying how
    /// many were left out, so a title is never cut in the middle.
    public func lines(maxBullets: Int? = nil) -> [String] {
        func shown(_ bullets: [String], empty: String) -> [String] {
            if bullets.isEmpty { return ["\u{2022} \(empty)"] }
            guard let maxBullets, bullets.count > maxBullets else { return bullets }
            return Array(bullets.prefix(maxBullets)) + ["\u{2022} \(bullets.count - maxBullets) more not shown; use query for this date"]
        }
        var out = [heading, "Done"] + shown(done, empty: "Nothing logged")
        if let counts { out.append(counts) }
        out.append("Next")
        out += shown(next, empty: "Nothing planned")
        out.append("Blockers: none")
        return out
    }

    public func text(maxBullets: Int? = nil) -> String { lines(maxBullets: maxBullets).joined(separator: "\n") }
}
