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
    /// False when the seal landed after the grace window, so the day is sealed but does not count for the streak.
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

/// The stand-up text a wrap-up copies, and the witness code on its last line.
public struct StandupText: Sendable, Equatable {
    public var text: String
    public var code: String
}

extension Journal {
    // MARK: - Seal

    /// Wraps up a day: carries every open task to the next workday, then records `day.sealed`, all in one
    /// transaction. Today and any past day can be sealed; a seal after the grace window is recorded but does
    /// not count for the streak.
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
            var dayZone: TimeZone
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
            return Sealed(at: event.at, carried: carried, counts: counts, plan: plan, dayZone: dayZone)
        }

        let sealedDate = Timestamp.parse(sealed.at) ?? clock.now()
        return SealResult(
            day: day, sealedAt: Timestamp.local(sealedDate, in: zone),
            counts: rules.sealCounts(sealedDate, for: day, in: sealed.dayZone), carried: sealed.carried,
            entryCounts: sealed.counts, plan: sealed.plan, streak: try streak(asOf: nil))
    }

    // MARK: - Streak

    /// Consecutive workdays sealed within grace, as of `asOf` (default today). One query for the days, one for
    /// the declarations, then a pure walk (`DayRules.streak`).
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
        var sealed: DayRules.SealedDays = [:]
        for row in try rows("SELECT date, tz, sealed_at FROM days ORDER BY date") {
            guard let date = row.text("date").flatMap({ LocalDate($0) }), date >= first else { continue }
            if let at = row.text("sealed_at").flatMap({ Timestamp.parse($0) }), at <= reference {
                sealed[date] = (at, row.text("tz").flatMap { TimeZone(identifier: $0) } ?? zone)
            }
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
        let today = self.today()
        let day = day ?? today
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
        var lines = ["*\(Self.standUpDate(day))*", "Done"]
        lines += entries.isEmpty ? ["\u{2022} Nothing logged"] : entries.map { bullet($0.title, $0.ticket) }

        let reviews = try rows(
            "SELECT COALESCE(SUM(quantity), 0) AS n FROM entries WHERE day = ? AND status = 'accepted' AND family = 'review'",
            [key]
        ).first?.int("n") ?? 0
        let merged = try rows(
            "SELECT COALESCE(SUM(quantity), 0) AS n FROM entries WHERE day = ? AND status = 'accepted' AND kind = 'pr.merged'",
            [key]
        ).first?.int("n") ?? 0
        let sessions = try rows(
            "SELECT COUNT(*) AS n FROM genai_sessions WHERE day = ? AND tool LIKE 'claude%'", [key]
        ).first?.int("n") ?? 0
        var parts: [String] = []
        if reviews > 0 { parts.append("Reviews \(reviews)") }
        if merged > 0 { parts.append("PRs merged \(merged)") }
        if sessions > 0 { parts.append("Claude Code \(sessions) session\(sessions == 1 ? "" : "s")") }
        if !parts.isEmpty { lines.append(parts.joined(separator: " \u{00B7} ")) }

        let next = DayRules(config: config).nextWorkday(after: day, declared: try declaredKinds())
        let tasks = try rows(
            "SELECT * FROM plan_tasks WHERE day = ? AND status = 'open' ORDER BY position, created_seq",
            [.text(next.description)]
        ).map { (row) throws(CadenceError) -> PlanTask in try Readers.task(row) }
        lines.append("Next")
        if tasks.isEmpty {
            lines.append("\u{2022} Nothing planned")
        }
        for task in tasks {
            var line = bullet(task.title, task.ticket)
            if let from = task.carriedFrom, let source = try? self.task(from), source.status == .slipped,
                let reason = source.reason
            {
                line += " (slipped: \(reason))"
            }
            lines.append(line)
        }
        lines.append("Blockers: none")

        let witness = try store.witness(day: day, actor: actor)
        lines.append(witness.line)
        return StandupText(text: lines.joined(separator: "\n"), code: witness.code)
    }

    private static func ticketSuffix(_ ticket: Ticket?, in title: String) -> String {
        guard let ticket, !title.contains(ticket.key) else { return "" }
        return " (\(ticket.key))"
    }

    /// "Thu 29 Oct".
    static func standUpDate(_ day: LocalDate) -> String {
        let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let parts = day.description.split(separator: "-").compactMap { Int($0) }
        let weekday = Weekday.allCases.firstIndex(of: day.weekday) ?? 0
        return "\(weekdays[weekday]) \(parts[2]) \(months[parts[1] - 1])"
    }
}
