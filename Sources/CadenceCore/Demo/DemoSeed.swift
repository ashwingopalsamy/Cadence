import Foundation

/// The ACME October demo (docs/SPEC.md sections 5.5 and 12.1; docs/PLAN.md T1.20). Everything is synthetic:
/// ACME tickets, git.example.com links and a sample name. The script is fixed, so seeding two fresh stores
/// gives the same projections and the same proof bytes.
///
/// Writes go through `Journal` and `store.append`. The clock is moved before each write, so recorded times
/// follow the day: a start between 09:30 and 10:15, work during the day, a wrap-up between 17:20 and 18:30.
public enum DemoSeed {
    public static let timezone = "Asia/Kolkata"
    public static let profileName = "Sample Person"
    public static let profileRole = "Software Engineer"
    /// The clock the demo starts from: genesis is written here (09:00 on Thu 1 Oct in the profile zone).
    public static let startInstant = "2026-10-01T03:30:00Z"

    /// The profile config the demo uses (Asia/Kolkata, Monday to Friday, boundary 04:00).
    public static func config() -> Config {
        var config = Config.defaults(timezone: timezone)
        config.profile.name = profileName
        config.profile.role = profileRole
        return config
    }

    /// Seeds October 2026 into an empty ledger. Refuses any ledger with events beyond its genesis.
    public static func seed(into journal: Journal, clock: ManualClock) throws(CadenceError) {
        guard try isEmpty(journal.store) else {
            throw .validation("the demo seed needs an empty store; use a new CADENCE_HOME")
        }
        let zone = journal.zone
        let entryIDs = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 2))
        let jitter = SeededRandomSource(seed: 2026)
        func noise(_ n: Int) -> Int { Int(jitter.bytes(1)[0]) % n }
        func at(_ day: LocalDate, _ minute: Int) -> Date {
            Timestamp.resolve(day, hour: minute / 60, minute: minute % 60, in: zone)
        }

        guard let first = LocalDate("2026-10-01"), let holiday = LocalDate("2026-10-02"),
            let leave = LocalDate("2026-10-23")
        else { throw .integrity("demo: bad calendar dates") }
        clock.set(at(first, 9 * 60))
        try journal.declare(holiday, kind: .holiday, label: "Gandhi Jayanti", actor: .app)
        try journal.declare(leave, kind: .leavePlanned, label: "Leave", actor: .app)

        var pending: [String: [String]] = [:]  // day -> ids of tasks carried onto it
        var reviewsSeen = 0
        for script in days {
            guard let day = LocalDate(script.date) else { throw .integrity("demo: bad date \(script.date)") }
            let start = 570 + noise(46)  // 09:30 to 10:15
            let seal = 1040 + noise(71)  // 17:20 to 18:30

            clock.set(at(day, start))
            try journal.startDay(day, at: nil, actor: .app)
            if script.onCall {
                try write(journal, [EventPayload.dayNoted(DayNoted(day: script.date, tz: timezone, onCall: true)).draft(actor: .app)])
            }

            // Plan the day. A task that is open at wrap-up is planned here and carried by the seal.
            var ids: [String?] = []
            for (i, task) in script.tasks.enumerated() {
                clock.set(at(day, start + 1 + i))
                let planned = try journal.planAdd(
                    title: task.title, day: day, estimateMin: i % 3 == 0 ? Int64(60) : nil, origin: .selfReported,
                    actor: .cli)
                ids.append(task.outcome == .carried ? nil : planned.id)
            }

            // The work, in order: carried copies first, then each task's outcome, with merged PRs, reviews
            // and logs spread between them.
            var ops: [Op] = (pending[script.date] ?? []).map { Op.resolve($0, .done, nil) }
            for (task, id) in zip(script.tasks, ids) {
                guard let id else { continue }
                switch task.outcome {
                case .done: ops.append(.resolve(id, .done, nil))
                case .reprioritised: ops.append(.resolve(id, .slipped, "reprioritised"))
                case .blocked: ops.append(.resolve(id, .slipped, "blocked"))
                case .dropped: ops.append(.resolve(id, .dropped, nil))
                case .carried: break
                }
            }
            ops = interleave(ops, script.prs.map { Op.merge($0) })
            let reviewOps: [Op] = (0..<script.reviews).map { _ in
                reviewsSeen += 1
                return Op.review(reviewsSeen - 1)
            }
            ops = interleave(ops, reviewOps)
            ops += script.logs.map { Op.log($0) }
            if let note = script.note { ops.append(.log(Log(kind: .note, title: note))) }

            let span = max(seal - 45 - (start + 30), 1)
            let step = max(span / max(ops.count, 1), 1)
            for (k, op) in ops.enumerated() {
                clock.set(at(day, start + 30 + k * step + noise(3)))
                try run(op, day: day, journal: journal, ids: entryIDs, clock: clock, zone: zone)
            }

            // AI sessions and one usage row a day, written before wrap-up.
            let sessions = script.sessions
            if sessions > 0 {
                clock.set(at(day, seal - 15))
                let compact = script.date.replacingOccurrences(of: "-", with: "")
                var drafts: [EventDraft] = []
                for n in 0..<sessions {
                    let began = start + 60 + n * 30
                    let session = GenAISession(
                        sessionId: "demo-\(compact)-\(n + 1)", tool: "claude-code", day: script.date,
                        startedAt: Timestamp.local(at(day, began), in: zone),
                        endedAt: Timestamp.local(at(day, began + 22), in: zone), turns: Int64(3 + n))
                    drafts.append(EventPayload.genaiSession(session).draft(actor: .collector("claude-code")))
                }
                let usage = GenAIUsage(
                    day: script.date, tool: "claude-code", model: "*", source: "transcripts", sessions: Int64(sessions),
                    tokens: TokenCounts(input: 150_000 + Int64(sessions) * 7_000, output: 12_000 + Int64(sessions) * 900),
                    estimated: false)
                drafts.append(EventPayload.genaiUsage(usage).draft(actor: .collector("claude-code")))
                try write(journal, drafts)
            }

            clock.set(at(day, seal - 5))
            try journal.endDay(day, at: nil, actor: .app)
            clock.set(at(day, seal))
            let result = try journal.seal(day, actor: .app)
            // A wrap-up copies the stand-up, so the demo proof carries a witness code for the day.
            _ = try journal.standup(day, actor: .app)
            for carried in result.carried {
                pending[carried.task.day, default: []].append(carried.task.id)
            }
        }
    }

    // MARK: - Writes

    /// One step of a day, in order.
    private enum Op {
        case resolve(String, TaskStatus, String?)
        case merge(PR)
        case review(Int)
        case log(Log)
    }

    private static func run(
        _ op: Op, day: LocalDate, journal: Journal, ids: ULIDGenerator, clock: ManualClock, zone: TimeZone
    ) throws(CadenceError) {
        switch op {
        case .resolve(let id, let status, let reason):
            _ = try journal.planResolve(taskID: id, status: status, reason: reason, note: nil, links: [], actor: .cli)
        case .merge(let pr):
            let cls: TicketClass = pr.selfInitiated ? .selfInitiated : .assigned
            let entry = Entry(
                id: ids.next(), day: day.description, kind: .prMerged,
                family: EntryKind.family(for: .prMerged, ticketClass: cls), title: pr.title,
                occurredAt: Timestamp.local(clock.now(), in: zone), ticket: Ticket(key: pr.ticket, class: cls),
                links: [Link(kind: .pr, url: "https://git.example.com/acme/\(pr.repo)/pull/\(pr.number)")],
                origin: .collected, source: "github", sourceRef: "github:acme/\(pr.repo)#\(pr.number)",
                status: .accepted, backfilled: false, afterSeal: false, export: .include)
            try write(journal, [EventPayload.entryCreated(entry).draft(actor: .collector("github"))])
        case .review(let n):
            let entry = Entry(
                id: ids.next(), day: day.description, kind: .reviewGiven,
                family: EntryKind.family(for: .reviewGiven, ticketClass: nil),
                title: reviewTitles[n % reviewTitles.count], occurredAt: Timestamp.local(clock.now(), in: zone),
                origin: .collected, source: "github", sourceRef: "github:review:\(day.description):\(n + 1)",
                status: .accepted, backfilled: false, afterSeal: false, export: .include)
            try write(journal, [EventPayload.entryCreated(entry).draft(actor: .collector("github"))])
        case .log(let log):
            _ = try journal.log(LogRequest(text: log.title, kind: log.kind, date: day), actor: .cli, origin: .selfReported)
        }
    }

    private static func write(_ journal: Journal, _ drafts: [EventDraft]) throws(CadenceError) {
        _ = try journal.store.append(drafts, then: { _ in })
    }

    private static func isEmpty(_ store: SQLiteStore) throws(CadenceError) -> Bool {
        let count = try store.eventCount()
        if count == 0 { return true }
        guard count == 1 else { return false }
        return try store.events(subject: "ledger").first?.type == "ledger.genesis"
    }

    /// Spreads `extra` through `base` at even positions, keeping the order of both.
    private static func interleave(_ base: [Op], _ extra: [Op]) -> [Op] {
        var out = base
        for (j, item) in extra.enumerated().reversed() {
            out.insert(item, at: min((j + 1) * (base.count + 1) / (extra.count + 1), out.count))
        }
        return out
    }

    // MARK: - Script

    private enum Outcome: Sendable, Equatable {
        case done, reprioritised, blocked, dropped
        /// Open at wrap-up, so the seal moves it to the next workday.
        case carried
    }

    private struct PlannedTask: Sendable {
        let title: String
        let outcome: Outcome
    }

    private struct PR: Sendable {
        let repo: String
        let number: Int
        let title: String
        let ticket: String
        let selfInitiated: Bool
    }

    private struct Log: Sendable {
        let kind: EntryKind
        let title: String
    }

    private struct DayScript: Sendable {
        let date: String
        let tasks: [PlannedTask]
        let prs: [PR]
        let reviews: Int
        let sessions: Int
        let onCall: Bool
        let logs: [Log]
        let note: String?
    }

    private static func task(_ title: String, _ outcome: Outcome) -> PlannedTask { PlannedTask(title: title, outcome: outcome) }

    private static func pr(_ repo: String, _ number: Int, _ title: String, _ ticket: String) -> PR {
        PR(repo: repo, number: number, title: title, ticket: ticket, selfInitiated: ticket == "ACME-000000")
    }

    private static func log(_ kind: EntryKind, _ title: String) -> Log { Log(kind: kind, title: title) }

    private static let reviewTitles = [
        "Reviewed idempotency keys for refunds", "Reviewed settlement batch job", "Reviewed rate limiter headers",
        "Reviewed retry jitter tests", "Reviewed webhook signature check", "Reviewed queue metrics",
        "Reviewed partner sandbox fixtures", "Reviewed ledger clock fix", "Reviewed capture timeout change",
        "Reviewed replay prototype", "Reviewed dead letter script", "Reviewed settlement schema migration",
    ]

    /// Oct 1 to 29, in order. Five tasks are open at wrap-up and carried; each copy is planned on the next workday.
    private static let days: [DayScript] = [
        DayScript(
            date: "2026-10-01",
            tasks: [
                task("ACME-482844 Idempotency keys for refunds", .done),
                task("Settlement batch reconciliation notes", .done),
                task("Capture timeout dashboard panel", .reprioritised),
                task("Draft idempotency ADR", .done),
                task("Webhook signature docs cleanup", .carried),
            ],
            prs: [pr("refunds", 371, "ACME-482844 Idempotency keys for refunds", "ACME-482844")],
            reviews: 3, sessions: 2, onCall: false,
            logs: [log(.workDone, "Paired on settlement tests")],
            note: "Week note: retry budget is the main risk this month"),
        DayScript(
            date: "2026-10-05",
            tasks: [
                task("ACME-482858 Batch settlement writes", .done),
                task("Retry budget config review", .blocked),
                task("Ledger test clock fix", .done),
            ],
            prs: [pr("ledger-core", 376, "ACME-482858 Batch settlement writes", "ACME-482858")],
            reviews: 2, sessions: 3, onCall: false,
            logs: [log(.workDone, "Wrote capture runbook section")], note: nil),
        DayScript(
            date: "2026-10-06",
            tasks: [
                task("Queue backpressure metrics spike", .done),
                task("Replay fixture review", .reprioritised),
                task("ACME-482861 Rate limiter headers", .done),
                task("Partner sandbox fixture audit", .dropped),
                task("Settlement schema migration plan", .carried),
            ],
            prs: [],
            reviews: 2, sessions: 2, onCall: false,
            logs: [log(.discussionRaised, "Alert routing for partner callbacks")],
            note: "Week note: partner callbacks are steady"),
        DayScript(
            date: "2026-10-07",
            tasks: [
                task("Capture path retry tests", .done),
                task("Refund ledger edge cases", .done),
                task("Oncall runbook update", .done),
            ],
            prs: [pr("webhooks", 380, "Replay fixture cleanup", "ACME-000000")],
            reviews: 3, sessions: 0, onCall: false,
            logs: [log(.workDone, "Investigated flaky refund test")], note: nil),
        DayScript(
            date: "2026-10-08",
            tasks: [
                task("ACME-482867 Retry jitter tests", .done),
                task("Webhook replay prototype design", .done),
                task("Ledger reconciliation query", .done),
                task("Capture path logging cleanup", .done),
            ],
            prs: [pr("capture-api", 382, "ACME-482861 Rate limiter headers", "ACME-482861")],
            reviews: 2, sessions: 3, onCall: false,
            logs: [log(.workDone, "Helped onboard a new starter")], note: nil),
        DayScript(
            date: "2026-10-09",
            tasks: [
                task("Partner callback retries", .done),
                task("Dead letter queue dashboards", .done),
                task("Batch writer idempotency check", .reprioritised),
                task("Refund webhook schema notes", .done),
            ],
            prs: [pr("capture-api", 384, "ACME-482867 Retry jitter tests", "ACME-482867")],
            reviews: 3, sessions: 2, onCall: false,
            logs: [log(.workDone, "Drafted partner callback notes")], note: nil),
        DayScript(
            date: "2026-10-12",
            tasks: [
                task("Settlement batch review prep", .done),
                task("Capture timeout alerts", .done),
                task("On call handover notes", .done),
                task("Partner fixture schema", .done),
            ],
            prs: [],
            reviews: 2, sessions: 3, onCall: false,
            logs: [log(.workDone, "Cleaned up webhook fixtures")], note: nil),
        DayScript(
            date: "2026-10-13",
            tasks: [
                task("Replay prototype scope doc", .done),
                task("Refund queue metrics naming", .dropped),
                task("ACME-482882 Settlement schema migration", .done),
                task("Queue backpressure ADR", .done),
                task("Settlement reconciliation backfill", .carried),
            ],
            prs: [pr("refunds", 388, "ACME-482879 Refund ledger balance check", "ACME-482879")],
            reviews: 2, sessions: 2, onCall: false,
            logs: [log(.meetingLed, "Queue backpressure design review")],
            note: "Week note: queue sizing decision lands Friday"),
        DayScript(
            date: "2026-10-14",
            tasks: [
                task("Settlement batch retry guard", .done),
                task("Capture replay limits", .done),
                task("Refund webhook docs", .done),
                task("Ops handover checklist", .carried),
            ],
            prs: [pr("ledger-core", 390, "ACME-482882 Settlement schema migration", "ACME-482882")],
            reviews: 3, sessions: 3, onCall: false,
            logs: [log(.workDone, "Triaged settlement alerts")], note: nil),
        DayScript(
            date: "2026-10-15",
            tasks: [
                task("Partner sandbox fixture audit follow up", .done),
                task("Capture logs sampling", .done),
                task("Settlement writer metrics", .done),
            ],
            prs: [],
            reviews: 2, sessions: 0, onCall: false,
            logs: [log(.workDone, "Updated capture dashboards")], note: nil),
        DayScript(
            date: "2026-10-16",
            tasks: [
                task("Queue backpressure follow up", .done),
                task("Webhook retry backoff", .blocked),
                task("Pairing notes for new starter", .done),
                task("Refund reconciliation spot check", .carried),
            ],
            prs: [pr("capture-api", 393, "ACME-482890 Queue backpressure metrics", "ACME-482890")],
            reviews: 3, sessions: 2, onCall: false,
            logs: [log(.mentoring, "Pairing with a new starter on the capture path")], note: nil),
        DayScript(
            date: "2026-10-19",
            tasks: [
                task("ACME-482890 Queue backpressure metrics", .done),
                task("Design review follow up notes", .done),
            ],
            prs: [],
            reviews: 2, sessions: 3, onCall: false,
            logs: [log(.workDone, "Paired on retry budget config")], note: nil),
        DayScript(
            date: "2026-10-20",
            tasks: [
                task("Dead letter replay tooling", .done),
                task("Capture sampling config", .reprioritised),
                task("Partner onboarding checklist", .done),
            ],
            prs: [pr("webhooks", 397, "Dead letter replay script", "ACME-000000")],
            reviews: 2, sessions: 2, onCall: false,
            logs: [log(.workDone, "Wrote settlement migration plan")],
            note: "Week note: partner callbacks are steady and the sandbox is ready"),
        DayScript(
            date: "2026-10-21",
            tasks: [
                task("ACME-482896 Partner sandbox fixtures", .done),
                task("Ledger test flake triage", .done),
                task("Settlement retry tuning notes", .done),
            ],
            prs: [pr("refunds", 399, "ACME-482896 Partner sandbox fixtures", "ACME-482896")],
            reviews: 3, sessions: 3, onCall: false,
            logs: [log(.workDone, "Fixed sandbox seed data")], note: nil),
        DayScript(
            date: "2026-10-22",
            tasks: [
                task("Webhook replay limits", .done),
                task("Capture path SLO draft", .done),
                task("Refund ledger alert tuning", .done),
            ],
            prs: [],
            reviews: 1, sessions: 2, onCall: false,
            logs: [log(.workDone, "Documented replay limits")], note: nil),
        // Week 44: Mon 26 to Thu 29 Oct.
        DayScript(
            date: "2026-10-26",
            tasks: [
                task("ACME-482871 Ledger test clock fix", .done),
                task("Retry budget rollout plan", .done),
                task("Replay tool scope call", .reprioritised),
                task("Capture alerts runbook", .done),
                task("Idempotency ADR final", .done),
            ],
            prs: [pr("ledger-core", 398, "ACME-482871 Ledger test clock fix", "ACME-482871")],
            reviews: 3, sessions: 5, onCall: false,
            logs: [
                log(.discussionRaised, "Retry budget ownership between capture and platform"),
                log(.meetingLed, "Weekly capture triage"),
                log(.workDone, "Sized the settlement batch work"),
            ],
            note: "Week note: the retry budget rollout is on track"),
        DayScript(
            date: "2026-10-27",
            tasks: [
                task("Webhook replay test matrix", .blocked),
                task("Settlement dashboard cleanup", .dropped),
                task("Capture logs review", .done),
                task("ACME-482889 Capture path timeout tuning", .done),
            ],
            prs: [pr("webhooks", 405, "Webhook replay prototype", "ACME-000000")],
            reviews: 3, sessions: 4, onCall: true,
            logs: [
                log(.discussionRaised, "Webhook replay scope with partners"),
                log(.incidentHandled, "Capture queue backlog during on call"),
                log(.mentoring, "Paired with a new engineer on ledger tests"),
                log(.workDone, "Tightened capture timeouts with the team"),
            ],
            note: nil),
        DayScript(
            date: "2026-10-28",
            tasks: [
                task("Retry budget rollout checks", .done),
                task("Refund reconciliation report", .done),
                task("Batch writer throughput test", .done),
                task("Architecture notes for settlement writes", .done),
                task("Queue metrics alert review", .done),
            ],
            prs: [pr("capture-api", 409, "ACME-482889 Capture path timeout tuning", "ACME-482889")],
            reviews: 3, sessions: 5, onCall: true,
            logs: [
                log(.decisionChallenged, "Challenged the single retry policy proposal"),
                log(.meetingLed, "Architecture review for settlement writes"),
                log(.mentoring, "Coached on writing a design doc"),
                log(.workDone, "Pairing on the webhook matrix"),
            ],
            note: nil),
        DayScript(
            date: "2026-10-29",
            tasks: [
                task("ACME-482913 Ship retry budget for capture path", .done),
                task("Webhook replay prototype wrap up", .done),
                task("Fixed flaky ledger test with deterministic clock", .done),
                task("Rate limiter review round follow ups", .reprioritised),
            ],
            prs: [pr("capture-api", 412, "ACME-482913 Ship retry budget for capture path", "ACME-482913")],
            reviews: 3, sessions: 5, onCall: false,
            logs: [
                log(.discussionRaised, "Idempotency keys for refunds with finance"),
                log(.workDone, "Wrote up the retry budget decision"),
            ],
            note: nil),
    ]
}
