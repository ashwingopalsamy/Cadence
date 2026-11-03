import Foundation

// Everything the store can say about one day that the surfaces need (docs/SPEC.md sections 4.1, 4.2, 5.1 and 5.2),
// read together so they agree. The app reads it inside one read transaction; what only the app knows (paused
// capture, a failing source, a running import, a store it cannot open) is added on top when the story is told.

/// The morning plan as committed (section 4.4).
extension Journal {
    /// Commits the plan for a day: the picked tasks first, in this order, and an optional focus line. The tasks
    /// must belong to that day and be open or resolved there; a task carried away from it cannot be listed.
    public func planCommit(day: LocalDate?, tasks: [String], focus: String?, actor: Actor) throws(CadenceError) {
        let day = day ?? today()
        guard Set(tasks).count == tasks.count else { throw .validation("tasks: a task is listed twice") }
        let focus = focus.map { Self.clean($0, limit: Self.maxTitle) }.flatMap { $0.isEmpty ? nil : $0 }
        try store.transact { () throws(CadenceError) -> Void in
            for id in tasks {
                guard let row = try self.rows("SELECT day, status FROM plan_tasks WHERE id = ?", [.text(id)]).first else {
                    throw .notFound("no plan task with id \(id)")
                }
                guard row.text("day") == day.description else { throw .validation("task \(id) belongs to another day") }
                guard row.text("status") != TaskStatus.moved.rawValue else {
                    throw .validation("task \(id) was carried to a later day")
                }
            }
            let committed = PlanCommitted(day: day.description, tz: try self.zone(of: day).identifier, focus: focus, tasks: tasks)
            try self.append([EventPayload.planCommitted(committed).draft(actor: actor)])
        }
    }

    /// "Move to tomorrow" (section 4.5): the task is resolved as slipped with its reason on its own day, and a carried
    /// copy joins the next workday that is not sealed (today at the earliest), where it shows up as carried.
    public func planMove(taskID: String, reason: String, actor: Actor) throws(CadenceError) -> CarriedTask {
        try store.transact { () throws(CadenceError) -> CarriedTask in
            let old = try self.task(taskID)
            guard old.status == .open else { throw .validation("task \(taskID) is already \(old.status.rawValue)") }
            guard let day = LocalDate(old.day) else { throw .integrity("task \(taskID) has no day") }
            _ = try self.planResolve(taskID: taskID, status: .slipped, reason: reason, note: nil, links: [], actor: actor)
            let target = try self.carryTarget(after: day, today: self.today(), rules: DayRules(config: self.config))
            let position = try self.rows(
                "SELECT COALESCE(MAX(position), 0) AS highest FROM plan_tasks WHERE day = ?", [.text(target.description)]
            ).first?.int("highest") ?? 0
            let copy = PlanTask(
                id: self.ids.next(), day: target.description, position: position + 1, title: old.title, ticket: old.ticket,
                estimateMin: old.estimateMin, origin: .carried, carriedFrom: old.id,
                plannedAt: Timestamp.local(self.clock.now(), in: self.zone))
            try self.append([EventPayload.planAdded(copy).draft(actor: actor)])
            return CarriedTask(from: old.id, task: copy)
        }
    }

    /// Edits an entry's title or kind as the person (section 4.6, Log and Inbox). It appends `entry.updated` with the old
    /// and new values, so the history keeps every version and nothing is overwritten; the origin never changes.
    @discardableResult
    public func entryEdit(entryID: String, title: String?, kind: EntryKind?, actor: Actor) throws(CadenceError) -> Entry {
        try store.transact { () throws(CadenceError) -> Entry in
            let entry = try self.entry(entryID)
            var fields: [String: Change] = [:]
            if let title {
                let cleaned = Self.clean(title, limit: Self.maxTitle)
                guard !cleaned.isEmpty else { throw .validation("title must not be empty") }
                if cleaned != entry.title { fields["title"] = Change(old: .string(entry.title), new: .string(cleaned)) }
            }
            if let kind, kind != entry.kind {
                fields["kind"] = Change(old: .string(entry.kind.rawValue), new: .string(kind.rawValue))
                let family = EntryKind.family(for: kind, ticketClass: entry.ticket?.class)
                if family != entry.family {
                    fields["family"] = Change(old: .string(entry.family.rawValue), new: .string(family.rawValue))
                }
            }
            guard !fields.isEmpty else { return entry }
            try self.append([EventPayload.entryUpdated(Changes(fields: fields)).draft(actor: actor, id: entryID)])
            return try self.entry(entryID)
        }
    }

    /// Whether a plan was committed for the day.
    public func isPlanCommitted(_ day: LocalDate) throws(CadenceError) -> Bool {
        try committedTasks(day) != nil
    }

    /// The tasks the latest commit for the day listed, or nil when no plan was committed.
    public func committedTasks(_ day: LocalDate) throws(CadenceError) -> [String]? {
        for event in try store.readEvents("SELECT * FROM events WHERE type = 'plan.committed' ORDER BY seq DESC", []) {
            if case .planCommitted(let committed)? = try? EventPayload(type: event.type, data: event.data),
                committed.day == day.description
            {
                return committed.tasks
            }
        }
        return nil
    }
}

/// The last workday before a day, when it was left unsealed (section 5.2, order 4).
public struct PreviousDay: Sendable, Equatable {
    public var date: LocalDate
    /// Its grace window is still open, so it can be wrapped up today.
    public var graceOpen: Bool
    /// Workdays sealed in a row before it.
    public var sealedBefore: Int
    /// Its plan and items logged, for the card that offers to wrap it up.
    public var planned: Int = 0
    public var done: Int = 0
    public var items: Int = 0
    /// It is the day's answer only until today has a plan or an item ("shown once", section 5.2); after that its card
    /// stays while its grace window is open, but today's own state leads.
    public var leads: Bool = true
}

public struct DayContext: Sendable, Equatable {
    public var view: DayView
    /// A plan was committed for the day.
    public var committed: Bool
    /// The day's tasks that count as its plan, in plan order: every task once the plan is committed; before that,
    /// the ones added by hand. Tasks carried away are left out.
    public var plan: [PlanTask]
    /// Tasks carried in from the last workday while the plan is not committed yet.
    public var carried: [PlanTask]
    /// Accepted entries of the day, oldest first.
    public var found: [Entry]
    /// Accepted entries that arrived after the day's seal.
    public var lateAdditions: Int
    public var aiSessions: Int
    public var inbox: Int
    public var rhythm: Rhythm
    public var previous: PreviousDay?
    public var streak: Streak?
    /// Wrap-up reminder times of the profile, "HH:MM", earliest first.
    public var wrapReminders: [String]
    /// Where the day starts, in minutes after midnight (04:00 is 240).
    public var boundaryMinutes: Int = 240
    /// The zone the day is read in.
    public var zone: String
    /// Workdays of this Monday-based week so far (today counts once it is sealed), and how many of them are sealed.
    public var weekWorkdays: Int = 0
    public var weekSealed: Int = 0
    /// What the morning plan may suggest (section 4.4).
    public var suggestions: [PlanSuggestionItem] = []

    public var resolved: Int { plan.filter { $0.status.isResolved }.count }
    public var done: Int { plan.filter { $0.status == .done }.count }

    /// The earliest wrap-up reminder that has passed at `now`, or nil. Times are read from the day boundary, so after
    /// midnight and before 04:00 the evening's reminders have still passed (late nights belong to the day, section 3).
    public func passedReminder(at now: Date) -> String? {
        let zone = TimeZone(identifier: zone) ?? .current
        func sinceBoundary(_ clock: String) -> Int? {
            let parts = clock.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            let minutes = parts[0] * 60 + parts[1] - boundaryMinutes
            return minutes < 0 ? minutes + 1440 : minutes
        }
        guard let now = sinceBoundary(Timestamp.clockTime(now, in: zone)) else { return nil }
        return wrapReminders.first { sinceBoundary($0).map { $0 <= now } ?? false }
    }

    /// The day story's input from what the store knows. The app adds what only it knows.
    public func storyInput(at now: Date) -> DayStory.Input {
        let date = LocalDate(view.day.date) ?? LocalDate(year: 1970, month: 1, day: 1)!
        var input = DayStory.Input(date: date)
        let zone = TimeZone(identifier: zone) ?? .current
        input.sealedAt = view.day.sealedAt.flatMap { Timestamp.parse($0) }.map { Timestamp.clockTime($0, in: zone) }
        input.lateAdditions = lateAdditions
        input.previous = previous.map {
            DayStory.Previous(
                date: $0.date, graceOpen: $0.graceOpen, sealedBefore: $0.sealedBefore, planned: $0.planned, done: $0.done,
                items: $0.items, leads: $0.leads)
        }
        input.dayOff = DayStory.DayOff(kind: view.day.kind, label: view.day.label)
        // The usual range counts its days without a calendar limit; the window's points only matter before it exists.
        input.countedWorkdays = rhythm.usual?.days ?? rhythm.points.filter { $0.items != nil && $0.date < date }.count
        input.onCall = view.day.onCall
        input.wrapUpReminder = passedReminder(at: now)
        input.planned = plan.count
        input.resolved = resolved
        input.done = done
        input.carried = carried.count
        input.items = rhythm.today
        input.aiSessions = aiSessions
        input.usualByNow = rhythm.byNow.map { $0.low...$0.high }
        return input
    }
}

extension Journal {
    /// Reads everything about a day the surfaces need. Call it inside one read transaction so the parts agree.
    public func dayContext(on day: LocalDate? = nil, at instant: Date? = nil) throws(CadenceError) -> DayContext {
        let now = instant ?? clock.now()
        let day = day ?? today()
        let view = try dayView(day)
        let picked = try committedTasks(day)
        let committed = picked != nil
        let tasks = view.tasks.filter { $0.status != .moved }
        // A carried task is part of the plan only when the morning commit picked it; one left behind was dropped
        // there and never planned for today. Tasks added by hand are always the plan.
        let chosen = Set(picked ?? [])
        let plan = tasks.filter { $0.origin != .carried || chosen.contains($0.id) }
        let carried = committed ? [] : tasks.filter { $0.origin == .carried && $0.status == .open }
        let found = view.entries.filter { $0.status == .accepted }
        let sessions = try rows("SELECT COUNT(*) AS n FROM genai_sessions WHERE day = ?", [.text(day.description)]).first?.int("n") ?? 0
        let reminders = config.reminders.filter { $0.kind == .wrap }.compactMap(\.at).sorted()
        let week = try weekSeals(through: day, todaySealed: view.day.sealedAt != nil)
        var previous = try previousDay(before: day, at: now)
        let todayIsQuiet = !committed && plan.isEmpty && !found.contains { $0.family != .presence && $0.family != .ai }
        previous?.leads = todayIsQuiet
        var context = DayContext(
            view: view, committed: committed, plan: plan, carried: carried, found: found,
            lateAdditions: found.filter(\.afterSeal).count, aiSessions: Int(sessions), inbox: try inbox().count,
            rhythm: try rhythm(on: day, at: now), previous: previous,
            streak: try? streak(), wrapReminders: reminders, zone: try zone(of: day).identifier,
            weekWorkdays: week.workdays, weekSealed: week.sealed)
        context.boundaryMinutes = config.dayBoundary.hour * 60 + config.dayBoundary.minute
        if !committed { context.suggestions = (try? planSuggestions(for: day)) ?? [] }
        return context
    }

    /// Workdays from this week's Monday up to the day before `day` (and `day` itself once sealed), and how many of them
    /// were sealed. Days off are not workdays, so they never count against you.
    func weekSeals(through day: LocalDate, todaySealed: Bool) throws(CadenceError) -> (workdays: Int, sealed: Int) {
        let rules = DayRules(config: config)
        let declared = try declaredKinds()
        let monday = day.adding(days: -(Weekday.allCases.firstIndex(of: day.weekday) ?? 0))
        let start = try ledgerStart().map { max($0, monday) } ?? monday
        var workdays = 0
        var sealed = 0
        for date in LocalDate.range(start, through: day) where rules.kind(of: date, declared: declared[date]) == .workday {
            if date == day && !todaySealed { continue }
            workdays += 1
            if try rows("SELECT sealed_at FROM days WHERE date = ?", [.text(date.description)]).first?.text("sealed_at") != nil {
                sealed += 1
            }
        }
        return (workdays, sealed)
    }

    /// The last workday before `day`, when it is unsealed, had something on it, and lies after the ledger began.
    /// Its grace window decides whether it is still open or closed unsealed.
    func previousDay(before day: LocalDate, at now: Date) throws(CadenceError) -> PreviousDay? {
        let rules = DayRules(config: config)
        let declared = try declaredKinds()
        var date = day.adding(days: -1)
        for _ in 0..<14 where rules.kind(of: date, declared: declared[date]) != .workday {
            date = date.adding(days: -1)
        }
        guard rules.kind(of: date, declared: declared[date]) == .workday else { return nil }
        if let start = try ledgerStart(), date < start { return nil }
        let view = try dayView(date)
        guard view.day.sealedAt == nil else { return nil }
        let active = view.entries.contains { $0.status == .accepted } || view.tasks.contains { $0.status != .moved }
        guard active else { return nil }
        let zone = try zone(of: date)
        let before = (try? streak(asOf: date.adding(days: -1)))?.current ?? 0
        let plan = view.tasks.filter { $0.status != .moved }
        let items = view.entries.filter { $0.status == .accepted && $0.family != .presence && $0.family != .ai }.count
        return PreviousDay(
            date: date, graceOpen: !rules.graceClosed(for: date, at: now, in: zone), sealedBefore: before,
            planned: plan.count, done: plan.filter { $0.status == .done }.count, items: items)
    }
}

/// Something the morning plan may suggest, always taken from an entry a source or you recorded: Cadence never
/// invents a task (section 4.4).
public struct PlanSuggestionItem: Sendable, Equatable {
    public var title: String
    public var family: Family
    /// Why it is suggested, as the row says it.
    public var reason: String
}

extension Journal {
    /// Pull requests opened in the last two weeks that have not merged, then tickets touched on the last workday that are
    /// not in today's tasks, at most two of each, never repeating a title already planned or carried.
    public func planSuggestions(for day: LocalDate) throws(CadenceError) -> [PlanSuggestionItem] {
        let today = try dayView(day)
        let taken = Set(today.tasks.map { $0.title.lowercased() })
        let takenTickets = Set(today.tasks.compactMap { $0.ticket?.key })
        let since = day.adding(days: -14)
        var opened: [Entry] = []
        var merged = Set<String>()
        for date in LocalDate.range(since, through: day) {
            for entry in try dayView(date).entries where entry.status == .accepted {
                let key = entry.ticket?.key ?? entry.links.first?.url
                if entry.kind == .prMerged, let key { merged.insert(key) }
                if entry.kind == .prOpened { opened.append(entry) }
            }
        }
        var items: [PlanSuggestionItem] = []
        for entry in opened.reversed() where items.count < 2 {
            let key = entry.ticket?.key ?? entry.links.first?.url
            guard key.map({ !merged.contains($0) && !takenTickets.contains($0) }) ?? true,
                !taken.contains(entry.title.lowercased()), !items.contains(where: { $0.title == entry.title })
            else { continue }
            items.append(PlanSuggestionItem(title: entry.title, family: .delivery, reason: "Open pull request, not merged yet"))
        }
        let rules = DayRules(config: config)
        let declared = try declaredKinds()
        var previous = day.adding(days: -1)
        for _ in 0..<14 where rules.kind(of: previous, declared: declared[previous]) != .workday { previous = previous.adding(days: -1) }
        var touched = 0
        for entry in try dayView(previous).entries.reversed() where entry.status == .accepted && touched < 2 {
            guard let ticket = entry.ticket, !takenTickets.contains(ticket.key), !merged.contains(ticket.key),
                !taken.contains(entry.title.lowercased()), !items.contains(where: { $0.title == entry.title })
            else { continue }
            items.append(PlanSuggestionItem(title: entry.title, family: entry.family, reason: "Ticket you touched last workday"))
            touched += 1
        }
        return items
    }
}
