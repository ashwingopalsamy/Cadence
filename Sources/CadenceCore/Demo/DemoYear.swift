import Foundation

/// Twelve months of ACME work, for measuring the app against a year of use (docs/PLAN.md T4.15). Like the October
/// demo, everything is synthetic (ACME tickets, git.example.com links) and the script is fixed, so two fresh stores get
/// the same projections and the same chain. It is never committed: a test or a make target writes it into a temporary
/// folder.
///
/// Every write goes through `Journal` and `store.append`, in one transaction, with the clock moved before each write so
/// recorded times follow the day. Each workday starts between 09:30 and 10:15, plans three to five tasks, does the
/// work (about a dozen logs, merged PRs and reviews, and AI sessions), and is wrapped up between 17:20 and 18:30 with a stand-up. A few
/// days are holidays, leave blocks and sick days. The last day, the one the budget tests call today, is started and
/// planned and left open.
extension DemoSeed {
    /// The last day of the year demo: a Friday after the October demo's last day.
    public static let yearEnd = LocalDate("2026-10-30")!

    /// The Monday that opens `weeks` weeks of work ending in the week of `end`.
    public static func yearFirstDay(endingOn end: LocalDate = yearEnd, weeks: Int = 52) -> LocalDate {
        let monday = end.adding(days: -(Weekday.allCases.firstIndex(of: end.weekday) ?? 0))
        return monday.adding(days: -7 * (weeks - 1))
    }

    /// 09:00 in the demo zone on the first day of `weeks` weeks ending on `end`. The ledger's genesis is written at the
    /// clock's time when the journal is made, so the journal is made with a clock set here.
    public static func yearStartInstant(endingOn end: LocalDate = yearEnd, weeks: Int = 52) -> Date {
        let zone = TimeZone(identifier: timezone) ?? .gmt
        return Timestamp.resolve(yearFirstDay(endingOn: end, weeks: weeks), hour: 9, minute: 0, in: zone)
    }

    /// Writes `weeks` weeks of work ending on `end` into an empty ledger. The clock is the journal's own and is left at
    /// the last write.
    public static func year(
        into journal: Journal, clock: ManualClock, endingOn end: LocalDate = yearEnd, weeks: Int = 52
    ) throws(CadenceError) {
        guard weeks >= 1 else { throw .validation("the year demo needs at least one week") }
        let count = try journal.store.eventCount()
        var onlyGenesis = count == 0
        if count == 1 { onlyGenesis = try journal.store.events(subject: "ledger").first?.type == "ledger.genesis" }
        guard onlyGenesis else { throw .validation("the demo year needs an empty store; use a new CADENCE_HOME") }
        let writer = YearWriter(journal: journal, clock: clock, end: end, weeks: weeks)
        try journal.store.transact { () throws(CadenceError) -> Void in try writer.run() }
    }
}

private struct YearWriter {
    let journal: Journal
    let clock: ManualClock
    let end: LocalDate
    let weeks: Int
    let zone: TimeZone
    let entryIDs: ULIDGenerator
    let random = SeededRandomSource(seed: 365)

    init(journal: Journal, clock: ManualClock, end: LocalDate, weeks: Int) {
        self.journal = journal
        self.clock = clock
        self.end = end
        self.weeks = weeks
        zone = journal.zone
        entryIDs = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 2))
    }

    // MARK: Random choices from a fixed stream

    func pick(_ n: Int) -> Int {
        let bytes = random.bytes(2)
        return (Int(bytes[0]) << 8 | Int(bytes[1])) % max(n, 1)
    }

    func choose<T>(_ items: [T]) -> T { items[pick(items.count)] }

    func at(_ day: LocalDate, _ minute: Int) -> Date {
        Timestamp.resolve(day, hour: minute / 60, minute: minute % 60, in: zone)
    }

    // MARK: The year

    func run() throws(CadenceError) {
        let first = DemoSeed.yearFirstDay(endingOn: end, weeks: weeks)
        let workdays = LocalDate.range(first, through: end).filter { $0.weekday != .sat && $0.weekday != .sun }
        let off = daysOff(workdays)

        var pending: [String: [String]] = [:]  // day -> ids of tasks carried onto it
        var nextPR = 100
        var reviewNumber = 0
        for day in workdays {
            if let declared = off[day] {
                clock.set(at(day, 9 * 60))
                try journal.declare(day, kind: declared.kind, label: declared.label, actor: .app)
                continue
            }
            let open = day == end
            let start = 570 + pick(46)  // 09:30 to 10:15
            let seal = 1040 + pick(71)  // 17:20 to 18:30
            clock.set(at(day, start))
            try journal.startDay(day, at: nil, actor: .app)

            // Plan the day: three to five tasks; one left open at wrap-up is carried by the seal.
            var planned: [(id: String?, outcome: Outcome)] = []
            for k in 0..<(3 + pick(3)) {
                clock.set(at(day, start + 1 + k))
                let task = try journal.planAdd(
                    title: taskTitle(), day: day, estimateMin: k % 3 == 0 ? Int64(60) : nil, origin: .selfReported, actor: .cli)
                planned.append((task.id, outcome()))
            }

            // The work, in order: carried copies from yesterday, then each task's outcome, with PRs, reviews and logs.
            var ops: [Op] = (pending[day.description] ?? []).map { Op.resolve($0, .done, nil) }
            for (id, outcome) in planned {
                guard let id else { continue }
                switch outcome {
                case .done: ops.append(.resolve(id, .done, nil))
                case .reprioritised: ops.append(.resolve(id, .slipped, "reprioritised"))
                case .blocked: ops.append(.resolve(id, .slipped, "blocked"))
                case .dropped: ops.append(.resolve(id, .dropped, nil))
                case .carried: break
                }
            }
            for _ in 0..<pick(4) {
                nextPR += 1
                ops.append(.merge(nextPR, repo: choose(Self.repos), subject: choose(Self.subjects), selfStarted: pick(5) == 0))
            }
            for _ in 0..<(2 + pick(5)) {
                reviewNumber += 1
                ops.append(.review(reviewNumber, subject: choose(Self.subjects)))
            }
            for _ in 0..<(3 + pick(7)) { ops.append(.log(logLine())) }
            if open {
                // Today: part of it is done. Nothing is sealed, so what is left is the open day's plan.
                ops = Array(ops.prefix(max(2, ops.count / 2)))
            }
            ops = shuffled(ops)

            let span = max(open ? 120 : seal - 45 - (start + 30), 1)
            let step = max(span / max(ops.count, 1), 1)
            for (k, op) in ops.enumerated() {
                clock.set(at(day, start + 30 + k * step + pick(3)))
                try run(op, day: day)
            }
            if open { return }

            // AI sessions and one usage row a day, before wrap-up.
            let sessions = pick(6) == 0 ? 0 : 1 + pick(5)
            if sessions > 0 {
                clock.set(at(day, seal - 15))
                try writeSessions(day, sessions: sessions, start: start)
            }

            clock.set(at(day, seal - 5))
            try journal.endDay(day, at: nil, actor: .app)
            clock.set(at(day, seal))
            let result = try journal.seal(day, actor: .app)
            _ = try journal.standup(day, actor: .app)
            for carried in result.carried { pending[carried.task.day, default: []].append(carried.task.id) }
        }
    }

    // MARK: Days off

    struct DayOff {
        var kind: DayKind
        var label: String?
    }

    /// Public holidays on their dates, four leave blocks of three to five workdays, and a few sick days. Never the
    /// last day, which is the open one.
    func daysOff(_ workdays: [LocalDate]) -> [LocalDate: DayOff] {
        var off: [LocalDate: DayOff] = [:]
        let holidays: [(month: Int, day: Int)] = [(1, 1), (1, 26), (8, 15), (10, 2), (12, 25)]
        for date in workdays where date != end && holidays.contains(where: { $0.month == date.month && $0.day == date.day }) {
            off[date] = DayOff(kind: .holiday, label: "Public holiday")
        }
        var cursor = 20
        while cursor < workdays.count - 5 {
            let length = 3 + (cursor % 3)
            for date in workdays[cursor..<min(cursor + length, workdays.count - 1)] where off[date] == nil {
                off[date] = DayOff(kind: .leavePlanned, label: "Leave")
            }
            cursor += 62
        }
        for _ in 0..<5 {
            let date = workdays[pick(workdays.count - 1)]
            if off[date] == nil { off[date] = DayOff(kind: .leaveUnplanned, label: "sick") }
        }
        return off
    }

    // MARK: Writes

    enum Outcome { case done, reprioritised, blocked, dropped, carried }

    func outcome() -> Outcome {
        switch pick(100) {
        case ..<70: .done
        case ..<78: .reprioritised
        case ..<84: .blocked
        case ..<88: .dropped
        default: .carried
        }
    }

    enum Op {
        case resolve(String, TaskStatus, String?)
        case merge(Int, repo: String, subject: String, selfStarted: Bool)
        case review(Int, subject: String)
        case log(Line)
    }

    struct Line {
        var kind: EntryKind
        var title: String
        var note: String?
    }

    func run(_ op: Op, day: LocalDate) throws(CadenceError) {
        switch op {
        case .resolve(let id, let status, let reason):
            _ = try journal.planResolve(taskID: id, status: status, reason: reason, note: nil, links: [], actor: .cli)
        case .merge(let number, let repo, let subject, let selfStarted):
            let ticketClass: TicketClass = selfStarted ? .selfInitiated : .assigned
            let key = selfStarted ? "ACME-000000" : "ACME-\(480_000 + number)"
            let entry = Entry(
                id: entryIDs.next(), day: day.description, kind: .prMerged,
                family: EntryKind.family(for: .prMerged, ticketClass: ticketClass),
                title: selfStarted ? subject : "\(key) \(subject)", occurredAt: Timestamp.local(clock.now(), in: zone),
                ticket: Ticket(key: key, class: ticketClass),
                links: [Link(kind: .pr, url: "https://git.example.com/acme/\(repo)/pull/\(number)")],
                origin: .collected, source: "github", sourceRef: "github:acme/\(repo)#\(number)", status: .accepted,
                backfilled: false, afterSeal: false, export: .include)
            try append([EventPayload.entryCreated(entry).draft(actor: .collector("github"))])
        case .review(let number, let subject):
            let entry = Entry(
                id: entryIDs.next(), day: day.description, kind: .reviewGiven,
                family: EntryKind.family(for: .reviewGiven, ticketClass: nil), title: "Reviewed \(subject)",
                occurredAt: Timestamp.local(clock.now(), in: zone), origin: .collected, source: "github",
                sourceRef: "github:review:\(day.description):\(number)", status: .accepted, backfilled: false, afterSeal: false,
                export: .include)
            try append([EventPayload.entryCreated(entry).draft(actor: .collector("github"))])
        case .log(let line):
            _ = try journal.log(
                LogRequest(text: line.title, kind: line.kind, date: day, note: line.note), actor: .cli, origin: .selfReported)
        }
    }

    func writeSessions(_ day: LocalDate, sessions: Int, start: Int) throws(CadenceError) {
        let compact = day.description.replacingOccurrences(of: "-", with: "")
        var drafts: [EventDraft] = []
        for n in 0..<sessions {
            let began = start + 60 + n * 30
            let session = GenAISession(
                sessionId: "demo-\(compact)-\(n + 1)", tool: "claude-code", day: day.description,
                startedAt: Timestamp.local(at(day, began), in: zone), endedAt: Timestamp.local(at(day, began + 22), in: zone),
                turns: Int64(3 + n))
            drafts.append(EventPayload.genaiSession(session).draft(actor: .collector("claude-code")))
        }
        let usage = GenAIUsage(
            day: day.description, tool: "claude-code", model: "*", source: "transcripts", sessions: Int64(sessions),
            tokens: TokenCounts(input: 150_000 + Int64(sessions) * 7_000, output: 12_000 + Int64(sessions) * 900),
            estimated: false)
        drafts.append(EventPayload.genaiUsage(usage).draft(actor: .collector("claude-code")))
        try append(drafts)
    }

    func append(_ drafts: [EventDraft]) throws(CadenceError) {
        _ = try journal.store.append(drafts, then: { _ in })
    }

    /// The same ops in a different but fixed order, so PRs and logs are not always after the tasks.
    func shuffled(_ ops: [Op]) -> [Op] {
        var out = ops
        guard out.count > 1 else { return out }
        for index in stride(from: out.count - 1, to: 0, by: -1) {
            // Only a small step, so a carried copy is still mostly resolved early in the day.
            let other = max(0, index - pick(4))
            out.swapAt(index, other)
        }
        return out
    }

    // MARK: Words

    func taskTitle() -> String {
        let subject = choose(Self.subjects)
        return pick(10) < 6 ? "ACME-\(480_000 + pick(5000)) \(subject)" : subject
    }

    func logLine() -> Line {
        let subject = choose(Self.subjects)
        let note = pick(5) == 0 ? choose(Self.notes) : nil
        switch pick(100) {
        case ..<62: return Line(kind: .workDone, title: "\(choose(Self.verbs)) \(subject)", note: note)
        case ..<72: return Line(kind: .discussionRaised, title: "Raised \(subject) with the team", note: note)
        case ..<80: return Line(kind: .meetingLed, title: "Led the \(subject) review", note: note)
        case ..<87: return Line(kind: .mentoring, title: "Coached a new starter on \(subject)", note: note)
        case ..<91: return Line(kind: .decisionChallenged, title: "Challenged the plan for \(subject)", note: note)
        case ..<95: return Line(kind: .docWritten, title: "Wrote up \(subject)", note: note)
        default: return Line(kind: .incidentHandled, title: "Handled an alert on \(subject)", note: note)
        }
    }

    static let repos = ["refunds", "ledger-core", "capture-api", "webhooks", "settlement", "partner-sandbox"]

    static let verbs = ["Paired on", "Fixed", "Investigated", "Triaged", "Updated", "Documented", "Tuned", "Cleaned up", "Sized"]

    static let subjects = [
        "idempotency keys for refunds", "settlement batch reconciliation", "the capture timeout dashboard",
        "webhook signature checks", "the retry budget config", "rate limiter headers", "the ledger test clock",
        "partner sandbox fixtures", "queue backpressure metrics", "dead letter replay tooling", "the refund ledger balance check",
        "the settlement schema migration", "the webhook replay prototype", "batch writer throughput", "capture path logging",
        "partner callback retries", "alert routing for callbacks", "the reconciliation backfill", "the idempotency ADR",
        "the capture alerts runbook", "refund webhook docs", "replay limits", "the ops handover checklist",
        "on call handover notes", "retry jitter tests", "sampling config for capture logs", "settlement writer metrics",
        "the queue sizing decision", "the partner fixture schema", "refund reconciliation spot checks", "the replay tool scope",
        "settlement retry guard", "capture replay limits", "the dead letter dashboards", "partner onboarding checklist",
        "the batch writer idempotency check", "webhook retry backoff", "the settlement alert tuning",
        "the architecture notes for settlement writes", "capture path SLO draft",
    ]

    static let notes = [
        "Followed up with the capture team about timeouts", "Waiting on the partner sandbox keys",
        "Decision recorded in the settlement ADR", "Needs a second look before the Friday cut",
        "Raised again at the weekly triage", "Retry budget stays at three attempts for now",
        "Open question about the replay window", "Handed over to the on call engineer",
    ]
}
