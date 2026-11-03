// Today in its main states on one example day, for the snapshot sheet and the tests. Every name, ticket and number is
// example data: an ACME team on Thursday 29 October 2026, with the October history of docs/SPEC.md section 5.
import CadenceCore
import Foundation

public struct TodaySpecimen: Sendable, Identifiable {
    public let name: String
    public let input: TodayInput

    public var id: String { name }

    /// The states the snapshot shows, in the order of the sheet.
    public static var all: [TodaySpecimen] {
        [
            inRhythm, moreThanUsual, fewerThanUsual, morning, planSettled, wrapUpDue, sealed, yesterdayOpen, onCall, leave,
            paused, sourceBehind, storeProblem,
        ]
    }

    public static var inRhythm: TodaySpecimen {
        make("In rhythm", at: "16:48", start: "09:41", tasks: tasks(), found: found())
    }

    public static var moreThanUsual: TodaySpecimen {
        make("More than usual", at: "16:48", start: "09:12", tasks: tasks(), found: found() + extra())
    }

    public static var fewerThanUsual: TodaySpecimen {
        let open = tasks().enumerated().map { $0.offset > 1 ? reopened($0.element) : $0.element }
        return make("Fewer than usual", at: "15:10", start: "10:02", tasks: open, found: Array(found().prefix(3)))
    }

    public static var morning: TodaySpecimen {
        let carried = [
            task(4, "Update the on-call runbook", origin: .carried),
            task(6, "Draft webhook replay prototype", ticket: "SELF-114", origin: .carried),
        ]
        return make("Morning", at: "09:12", start: nil, tasks: [], found: [], carried: carried)
    }

    public static var planSettled: TodaySpecimen {
        let settled = tasks().map { $0.status == .open ? resolved($0, .done) : $0 }
        return make("Plan settled", at: "16:30", start: "09:41", tasks: settled, found: found())
    }

    public static var wrapUpDue: TodaySpecimen {
        make("Wrap-up due", at: "17:32", start: "09:41", tasks: tasks(), found: found()) { $0.wrapUpReminder = "17:30" }
    }

    public static var sealed: TodaySpecimen {
        let settled = tasks().map { $0.status == .open ? resolved($0, .done) : $0 }
        let late = entry(20, "17:30", "Merged: rate limiter tuning", .prMerged, .collected)
        return make("Sealed", at: "18:14", start: "09:41", end: "18:12", tasks: settled, found: found() + [late]) {
            $0.sealedAt = "18:12"
        }
    }

    public static var yesterdayOpen: TodaySpecimen {
        make("Yesterday still open", at: "09:08", start: nil, tasks: [], found: []) {
            $0.previous = DayStory.Previous(date: day.adding(days: -1), graceOpen: true, sealedBefore: 18)
        }
    }

    public static var onCall: TodaySpecimen {
        let three = Array(tasks().prefix(3)).enumerated().map { $0.offset == 2 ? reopened($0.element) : $0.element }
        return make("On call", at: "14:22", start: "08:30", tasks: three, found: Array(found().prefix(7))) { $0.onCall = true }
    }

    public static var leave: TodaySpecimen {
        make("On leave", at: "11:00", start: nil, tasks: [], found: [], week: WeekSeals(sealed: 3, workdays: 3)) {
            $0.dayOff = .leave
        }
    }

    public static var paused: TodaySpecimen {
        make("Capture paused", at: "13:05", start: "09:41", tasks: Array(tasks().prefix(4)), found: Array(found().prefix(5))) {
            $0.paused = true
        }
    }

    public static var sourceBehind: TodaySpecimen {
        make("A source is behind", at: "16:48", start: "09:41", tasks: tasks(), found: Array(found().prefix(7))) {
            $0.behind = DayStory.Behind(source: "GitHub", lastSync: "13:40")
        }
    }

    public static var storeProblem: TodaySpecimen {
        var day = DayStory.Input(date: day)
        day.storeProblem = true
        let input = TodayInput(day: day, zone: zone, now: at("10:20"), locale: locale, failure: .denied)
        return TodaySpecimen(name: "Store problem", input: input)
    }

    // MARK: The example day

    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    static let locale = Locale(identifier: "en_GB")
    static let day = LocalDate(year: 2026, month: 10, day: 29)!

    /// Items logged per counted workday, 1 to 28 October. Weekends are gaps, never zeros.
    static let history: [(day: Int, items: Int)] = [
        (1, 5), (2, 7), (5, 6), (6, 8), (7, 7), (8, 4), (9, 8), (12, 6), (13, 9), (14, 5), (15, 7), (16, 8), (19, 9), (20, 6),
        (21, 5), (22, 8), (23, 7), (26, 5), (27, 7), (28, 8),
    ]

    static func at(_ clock: String) -> Date { Timestamp.instant(clockTime: clock, on: day, in: zone)! }

    static func make(
        _ name: String, at clock: String, start: String?, end: String? = nil, tasks: [PlanTask], found: [Entry],
        carried: [PlanTask] = [], week: WeekSeals? = nil, adjust: (inout DayStory.Input) -> Void = { _ in }
    ) -> TodaySpecimen {
        let items = found.filter { $0.family != .ai && $0.family != .presence }.count
        let range = byNow(clock)
        var input = DayStory.Input(date: day)
        input.countedWorkdays = history.count
        input.planned = tasks.count
        input.resolved = tasks.filter { $0.status.isResolved }.count
        input.done = tasks.filter { $0.status == .done }.count
        input.carried = carried.count
        input.items = items
        input.aiSessions = found.filter { $0.family == .ai }.count
        input.usualByNow = range.low...range.high
        adjust(&input)
        let stamped = found.map { e -> Entry in
            var e = e
            if let sealed = input.sealedAt, let at = e.occurredAt.flatMap({ Timestamp.parse($0) }) {
                e.afterSeal = at > Self.at(sealed)
            }
            return e
        }
        input.lateAdditions = stamped.filter(\.afterSeal).count
        let today = TodayInput(
            day: input, zone: zone, now: at(clock), locale: locale, firstActivity: start.map(at), lastActivity: end.map(at),
            plan: tasks, carried: carried, found: stamped, rhythm: rhythm(today: items, byNow: range), week: week)
        return TodaySpecimen(name: name, input: today)
    }

    static func rhythm(today: Int, byNow: UsualRange) -> Rhythm {
        let counted = Dictionary(uniqueKeysWithValues: history.map { ($0.day, $0.items) })
        let first = LocalDate(year: 2026, month: 10, day: 1)!
        var values: [Int] = []
        let points = LocalDate.range(first, through: day).map { date -> RhythmPoint in
            let point = RhythmPoint(date: date, items: date == day ? nil : counted[date.day], usual: UsualRange.of(values))
            if let items = point.items { values.append(items) }
            return point
        }
        return Rhythm(today: today, usual: UsualRange.of(values), byNow: byNow, plan: nil, points: points)
    }

    /// The share of a usual day that has normally landed by this time, as the prototype's example curve has it.
    static func byNow(_ clock: String) -> UsualRange {
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        let hours = parts[0] + parts[1] / 60
        let elapsed = min(1, max(0, (hours - 9.5) / 8))
        let share = 1 - pow(1 - elapsed, 1.5)
        let usual = UsualRange.of(history.map(\.items))!
        func scaled(_ n: Int) -> Int { Int((Double(n) * share).rounded()) }
        return UsualRange(low: scaled(usual.low), median: scaled(usual.median), high: max(1, scaled(usual.high)), days: usual.days)
    }

    static func task(_ n: Int, _ title: String, ticket: String? = nil, status: TaskStatus = .open, reason: String? = nil, origin: PlanOrigin = .selfReported) -> PlanTask {
        PlanTask(
            id: "task-\(n)", day: day.description, position: Int64(n), title: title,
            ticket: ticket.map { Ticket(key: $0, class: $0.hasPrefix("SELF") ? .selfInitiated : .assigned) }, origin: origin,
            status: status, reason: reason, plannedAt: Timestamp.utc(at("09:30")))
    }

    static func tasks() -> [PlanTask] {
        [
            task(1, "Ship retry budget for capture path", ticket: "ACME-482913", status: .done),
            task(2, "Review settlement batching RFC", status: .done),
            task(3, "Draft webhook replay prototype", ticket: "SELF-114", status: .slipped, reason: SlipReason.reprioritised.rawValue),
            task(4, "Update the on-call runbook"),
            task(5, "Prepare design review notes"),
        ]
    }

    static func reopened(_ task: PlanTask) -> PlanTask {
        var task = task
        task.status = .open
        task.reason = nil
        return task
    }

    static func resolved(_ task: PlanTask, _ status: TaskStatus) -> PlanTask {
        var task = task
        task.status = status
        return task
    }

    static func entry(_ n: Int, _ clock: String, _ title: String, _ kind: EntryKind, _ origin: Origin, ticket: String? = nil) -> Entry {
        Entry(
            id: "entry-\(n)", day: day.description, kind: kind, family: EntryKind.family(for: kind, ticketClass: nil), title: title,
            occurredAt: Timestamp.utc(at(clock)), ticket: ticket.map { Ticket(key: $0, class: .assigned) }, origin: origin,
            source: origin == .selfReported ? nil : "github")
    }

    static func found() -> [Entry] {
        [
            entry(11, "10:14", "Reviewed: rate limiter round 2", .reviewGiven, .collected),
            entry(12, "10:48", "Claude Code session, 42 min", .genaiSession, .observed),
            entry(13, "11:42", "Merged: retry budget for capture path", .prMerged, .collected, ticket: "ACME-482913"),
            entry(14, "12:20", "Led the settlement design review", .meetingLed, .selfReported),
            entry(15, "14:05", "Reviewed: ledger test clock fix", .reviewGiven, .collected),
            entry(16, "15:12", "Merged: ledger test clock fix", .prMerged, .collected),
            entry(17, "15:50", "Handled the webhook retry alert", .incidentHandled, .selfReported),
            entry(18, "16:20", "Reviewed settlement batching RFC", .reviewGiven, .collected),
            entry(19, "16:44", "Claude Code session, 31 min", .genaiSession, .observed),
        ]
    }

    static func extra() -> [Entry] {
        let titles: [(String, EntryKind)] = [
            ("Merged: rate limiter tuning", .prMerged), ("Reviewed: proof export fix", .reviewGiven),
            ("Reviewed: collector backoff", .reviewGiven), ("Mentored on the ledger model", .mentoring),
            ("Merged: spool drain batching", .prMerged), ("Challenged the retry default", .decisionChallenged),
        ]
        return titles.enumerated().map { i, item in
            entry(40 + i, "16:1\(i)", item.0, item.1, i % 3 == 0 ? .collected : .selfReported)
        }
    }
}
