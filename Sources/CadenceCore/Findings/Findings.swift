import Foundation

// The findings engine (docs/SPEC.md sections 5.4 and 5.5; docs/PLAN.md T4.5). Every finding is one sentence
// built from a fixed template and the figures of a `Summary`. A figure that is unknown leaves its clause out,
// and a finding with no known figure is not written: unknown is not zero. There is no comparison with any
// earlier record ("best since" is never written), and a trend needs at least three weekly points.

/// What a finding is about. The raw value is its key in JSON.
public enum FindingKind: String, Sendable, CaseIterable {
    /// Recap frame 1: merged, reviewed, discussions raised.
    case delivery
    /// Recap frame 2: planned tasks done, and the slips by reason.
    case plan
    /// Plan done by week, only when at least three weeks move the same way (section 5.4, weeks start Monday).
    case planTrend = "plan_trend"
    /// Recap frame 4: leadership signals, on call and incidents.
    case presence
    /// Recap frame 5: AI days, sessions and AI-assisted merges.
    case ai
    /// Section 5.4: how much of the work is self-started.
    case selfInitiated = "self_initiated"
    /// Section 5.4: the shape of the days.
    case dayShape = "day_shape"
    /// Section 5.4: review cadence, days with at least one review.
    case reviewCadence = "review_cadence"
}

/// One computed sentence and the figures it was written from.
public struct Finding: Sendable, Equatable {
    public var kind: FindingKind
    public var text: String
    /// Every figure the text states, and nothing it does not.
    public var figures: JSONValue

    public init(kind: FindingKind, text: String, figures: JSONValue) {
        self.kind = kind
        self.text = text
        self.figures = figures
    }

    public var json: JSONValue { ["kind": .string(kind.rawValue), "text": .string(text), "figures": figures] }
}

/// Planned tasks done in one Monday-based week, clipped to the range, over counted workdays.
public struct WeekPlan: Sendable, Equatable {
    public var monday: LocalDate
    public var done: Int
    public var total: Int

    public init(monday: LocalDate, done: Int, total: Int) {
        self.monday = monday
        self.done = done
        self.total = total
    }
}

/// The direction of a run of points.
public enum TrendDirection: String, Sendable {
    case up, down
}

public enum Findings {
    // MARK: thresholds

    /// A trend needs at least this many points. Two points never make one (section 5.5).
    public static let minTrendPoints = 3
    /// A week is a point of the plan trend only with at least this many counted planned tasks; a thinner week
    /// is no point at all and ends the run, as a week with no plan does.
    public static let minTasksPerWeek = 5
    /// The run must move at least this many percentage points from its first point to its last.
    public static let minTrendChange = 5

    /// The order findings are written in: the recap frames first (section 5.5), then the other charts of
    /// section 5.4. Each kind gives at most one finding, so there is nothing to rank and no tie to break.
    public static let order: [FindingKind] = FindingKind.allCases

    static let definition =
        "Sentences computed by Cadence from fixed templates over the figures of this summary; a figure with no data leaves its clause out, and a trend needs at least three weekly points"

    // MARK: engine

    /// The findings for a summary, in `order`. A text that fails `lint` is dropped, never shown.
    public static func make(_ s: Summary) -> [Finding] {
        order.compactMap { kind -> Finding? in
            switch kind {
            case .delivery: delivery(s)
            case .plan: plan(s)
            case .planTrend: planTrend(s.weeklyPlan)
            case .presence: presence(s)
            case .ai: ai(s)
            case .selfInitiated: selfInitiated(s)
            case .dayShape: dayShape(s)
            case .reviewCadence: reviewCadence(s)
            }
        }
        .filter { lint($0.text) }
    }

    /// True when a text keeps the copy rules the engine promises: no "best since", and the rules of section 6.6
    /// (no en or em dash, none of the banned words).
    public static func lint(_ text: String) -> Bool {
        !text.lowercased().contains("best since") && CopyRules.allows(text)
    }

    // MARK: templates

    /// "You merged 4 PRs, reviewed 12 and raised 3 discussions." The range is the recap's caption, so it is not
    /// repeated here.
    static func delivery(_ s: Summary) -> Finding? {
        var clauses: [String] = []
        var figures: [String: JSONValue] = [:]
        if let merged = s.mergedPRs {
            clauses.append("merged \(count(merged, "PR"))")
            figures["merged_prs"] = .int(Int64(merged))
        }
        if let reviews = s.reviews {
            clauses.append("reviewed \(reviews)")
            figures["reviews"] = .int(Int64(reviews))
        }
        if let kinds = s.kindCounts {
            let raised = kinds[EntryKind.discussionRaised.rawValue] ?? 0
            clauses.append("raised \(count(raised, "discussion"))")
            figures["discussions_raised"] = .int(Int64(raised))
        }
        guard !clauses.isEmpty else { return nil }
        return Finding(kind: .delivery, text: "You " + list(clauses) + ".", figures: .object(figures))
    }

    /// "78% of your plan got done. 14 of 18 tasks. 3 slipped: 2 reprioritised and 1 blocked." Reasons by count,
    /// largest first, then by name. No slip is stated as "None slipped."
    static func plan(_ s: Summary) -> Finding? {
        guard let done = s.planDone, let total = s.planTotal, total > 0, let percent = GenAIMetrics.percent(Int64(done), of: Int64(total))
        else { return nil }
        var text = "\(percent)% of your plan got done. \(done) of \(count(total, "task"))."
        // Stored reasons are free text. Only the fixed chips are named; anything else is "for another reason", so
        // a typed reason can never put its own words, case or dashes into the sentence.
        var slips: [String: Int] = [:]
        for (reason, n) in s.slipsByReason ?? [:] where n > 0 {
            let key = reason == "unspecified" ? reason : SlipReason(stored: reason)?.rawValue ?? "other"
            slips[key, default: 0] += n
        }
        let slipped = slips.values.reduce(0, +)
        if s.slipsByReason != nil {
            if slipped == 0 {
                text += " None slipped."
            } else {
                let reasons = slips.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .map { "\($0.value) \(reasonPhrase($0.key))" }
                text += " \(slipped) slipped: " + list(reasons) + "."
            }
        }
        var figures: [String: JSONValue] = [
            "done": .int(Int64(done)), "of": .int(Int64(total)), "percent": .int(Int64(percent)),
        ]
        if s.slipsByReason != nil {
            figures["slipped"] = .int(Int64(slipped))
            figures["slipped_by_reason"] = .object(slips.mapValues { .int(Int64($0)) })
        }
        return Finding(kind: .plan, text: text, figures: .object(figures))
    }

    /// "Plan done rose across 3 weeks: 80%, 89%, 92%." Only the run that ends at the latest week counts.
    static func planTrend(_ weeks: [WeekPlan]) -> Finding? {
        // A week below the task threshold is no point; it ends the run like a gap.
        let points: [(WeekPlan, Int)?] = weeks.map { week in
            guard week.total >= minTasksPerWeek, let percent = GenAIMetrics.percent(Int64(week.done), of: Int64(week.total))
            else { return nil }
            return (week, percent)
        }
        var run: [(WeekPlan, Int)] = []
        for point in points.reversed() {
            guard let point else { break }
            run.insert(point, at: 0)
        }
        guard let direction = trend(run.map(\.1)) else { return nil }
        let length = trendLength(run.map(\.1), direction)
        let tail = Array(run.suffix(length))
        let verb = direction == .up ? "rose" : "fell"
        let text = "Plan done \(verb) across \(tail.count) weeks: " + tail.map { "\($0.1)%" }.joined(separator: ", ") + "."
        let figures: JSONValue = [
            "direction": .string(direction.rawValue),
            "weeks": .array(tail.map { week, percent in
                [
                    "week_of": .string(week.monday.description), "done": .int(Int64(week.done)), "of": .int(Int64(week.total)),
                    "percent": .int(Int64(percent)),
                ]
            }),
        ]
        return Finding(kind: .planTrend, text: text, figures: figures)
    }

    /// The direction of the run that ends at the last point, when it has at least `minTrendPoints` points that
    /// each move strictly the same way and moves at least `minTrendChange` overall. Equal neighbours are no move.
    public static func trend(_ values: [Int]) -> TrendDirection? {
        guard values.count >= 2 else { return nil }
        let last = values[values.count - 1]
        let before = values[values.count - 2]
        guard last != before else { return nil }
        let direction: TrendDirection = last > before ? .up : .down
        let length = trendLength(values, direction)
        guard length >= minTrendPoints else { return nil }
        let first = values[values.count - length]
        guard abs(last - first) >= minTrendChange else { return nil }
        return direction
    }

    /// How many trailing points move strictly in `direction`, counting the first of them.
    static func trendLength(_ values: [Int], _ direction: TrendDirection) -> Int {
        guard !values.isEmpty else { return 0 }
        var length = 1
        var i = values.count - 1
        while i > 0 {
            let moved = direction == .up ? values[i] > values[i - 1] : values[i] < values[i - 1]
            guard moved else { break }
            length += 1
            i -= 1
        }
        return length
    }

    /// "Led 2 meetings, challenged 1 decision and mentored twice. On call Tue to Wed, with 1 incident."
    /// A part with a count of 0 is left out; with every part 0 it reads "Nothing beyond the plan was logged."
    static func presence(_ s: Summary) -> Finding? {
        guard let kinds = s.kindCounts else { return nil }
        let led = kinds[EntryKind.meetingLed.rawValue] ?? 0
        let challenged = kinds[EntryKind.decisionChallenged.rawValue] ?? 0
        let mentored = kinds[EntryKind.mentoring.rawValue] ?? 0
        let incidents = kinds[EntryKind.incidentHandled.rawValue] ?? 0
        var parts: [String] = []
        if led > 0 { parts.append("led \(count(led, "meeting"))") }
        if challenged > 0 { parts.append("challenged \(count(challenged, "decision"))") }
        if mentored > 0 { parts.append("mentored \(times(mentored))") }
        var sentences: [String] = []
        if s.onCallDays.isEmpty, incidents > 0 { parts.append("handled \(count(incidents, "incident"))") }
        if !parts.isEmpty { sentences.append(capitalizedFirst(list(parts)) + ".") }
        if !s.onCallDays.isEmpty {
            let span = onCallSpan(s.onCallDays, weekNames: singleWeek(s) != nil)
            sentences.append("On call \(span)" + (incidents > 0 ? ", with \(count(incidents, "incident"))." : "."))
        }
        var figures: [String: JSONValue] = [:]
        if sentences.isEmpty {
            // "Nothing beyond the plan" is only true when no kind beyond the plan was logged at all.
            guard beyondThePlan.allSatisfy({ (kinds[$0.rawValue] ?? 0) == 0 }) else { return nil }
            for kind in beyondThePlan { figures[kind.rawValue] = .int(0) }
            return Finding(kind: .presence, text: "Nothing beyond the plan was logged.", figures: .object(figures))
        }
        if led > 0 { figures["meetings_led"] = .int(Int64(led)) }
        if challenged > 0 { figures["decisions_challenged"] = .int(Int64(challenged)) }
        if mentored > 0 { figures["mentoring"] = .int(Int64(mentored)) }
        if incidents > 0 { figures["incidents"] = .int(Int64(incidents)) }
        if !s.onCallDays.isEmpty { figures["on_call_days"] = .array(s.onCallDays.map { .string($0.description) }) }
        return Finding(kind: .presence, text: sentences.joined(separator: " "), figures: .object(figures))
    }

    /// "19 Claude Code sessions. Across 4 of 4 workdays. 2 of your 4 merged PRs were AI-assisted."
    static func ai(_ s: Summary) -> Finding? {
        var parts: [String] = []
        var figures: [String: JSONValue] = [:]
        if let sessions = s.aiSessions {
            parts.append(count(sessions, "Claude Code session") + ".")
            figures["sessions"] = .int(Int64(sessions))
        }
        if let days = s.aiDays, s.aiCountedDays > 0 {
            let lead = s.aiSessions == nil ? "Claude Code on" : "Across"
            parts.append("\(lead) \(days) of \(count(s.aiCountedDays, "workday")).")
            figures["ai_days"] = .int(Int64(days))
            figures["ai_counted_days"] = .int(Int64(s.aiCountedDays))
        }
        if let assisted = s.assistedMerges, assisted.share.of > 0 {
            let of = assisted.share.of
            let marker = assisted.unrecorded > 0 ? " with a recorded marker" : ""
            let verb = assisted.share.value == 1 ? "was" : "were"
            parts.append("\(assisted.share.value) of your \(of) merged \(of == 1 ? "PR" : "PRs")\(marker) \(verb) AI-assisted.")
            figures["assisted_merges"] = .int(Int64(assisted.share.value))
            figures["merged_with_marker"] = .int(Int64(of))
            figures["unrecorded"] = .int(Int64(assisted.unrecorded))
        }
        guard !parts.isEmpty else { return nil }
        return Finding(kind: .ai, text: parts.joined(separator: " "), figures: .object(figures))
    }

    /// "3 of 14 merged PRs were self-started." Needs at least one merged PR.
    static func selfInitiated(_ s: Summary) -> Finding? {
        guard let merged = s.mergedPRs, merged > 0, let own = s.selfInitiatedPRs else { return nil }
        let text = "\(own) of \(merged) merged \(merged == 1 ? "PR" : "PRs") \(own == 1 ? "was" : "were") self-started."
        return Finding(
            kind: .selfInitiated, text: text,
            figures: ["self_initiated": .int(Int64(own)), "merged_prs": .int(Int64(merged))])
    }

    /// "Your usual day ran from 09:52 to 17:58, over 4 days." Usual is the median. When the starts and ends cover a different
    /// number of days, each is stated on its own.
    static func dayShape(_ s: Summary) -> Finding? {
        var figures: [String: JSONValue] = ["tz": .string(s.zone)]
        if let first = s.firstActivity { figures["first_activity"] = first.json }
        if let last = s.lastActivity { figures["last_activity"] = last.json }
        let text: String
        switch (s.firstActivity, s.lastActivity) {
        case (let first?, let last?) where first.days == last.days:
            text = "Your usual day ran from \(first.median) to \(last.median), over \(count(first.days, "day"))."
        case (let first?, let last?):
            text = "Your usual start was \(first.median), over \(count(first.days, "day")). Your usual end was \(last.median), over \(count(last.days, "day"))."
        case (let first?, nil):
            text = "Your usual start was \(first.median), over \(count(first.days, "day"))."
        case (nil, let last?):
            text = "Your usual end was \(last.median), over \(count(last.days, "day"))."
        case (nil, nil):
            return nil
        }
        return Finding(kind: .dayShape, text: text, figures: .object(figures))
    }

    /// "You reviewed on 18 of 19 workdays this month." Over counted workdays.
    static func reviewCadence(_ s: Summary) -> Finding? {
        guard let days = s.reviewDays, s.countedWorkdays > 0 else { return nil }
        let text = "You reviewed on \(days) of \(count(s.countedWorkdays, "workday")) \(rangePhrase(s.label))."
        return Finding(
            kind: .reviewCadence, text: text,
            figures: ["review_days": .int(Int64(days)), "counted_workdays": .int(Int64(s.countedWorkdays))])
    }

    /// Things done that were never on a plan (section 5.4, Beyond the plan).
    static let beyondThePlan: [EntryKind] = [
        .meetingLed, .decisionChallenged, .mentoring, .incidentHandled, .discussionRaised, .initiativeStarted,
        .initiativeProgress, .docWritten,
    ]

    // MARK: wording

    /// A slip reason key as it reads after its count: "2 reprioritised", "1 too big", "1 with no reason".
    static func reasonPhrase(_ key: String) -> String {
        switch key {
        case "unspecified": "with no reason"
        case "other": "for another reason"
        default: SlipReason(rawValue: key)?.label.lowercased() ?? "for another reason"
        }
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    static func times(_ n: Int) -> String {
        switch n {
        case 1: "once"
        case 2: "twice"
        default: "\(n) times"
        }
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    static func rangePhrase(_ label: String) -> String {
        switch label {
        case "week": "this week"
        case "month": "this month"
        case "cycle": "this cycle"
        default: "in this range"
        }
    }

    static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func monday(of date: LocalDate) -> LocalDate {
        date.adding(days: -(Weekday.allCases.firstIndex(of: date.weekday) ?? 0))
    }

    /// The Monday of the one week the range lies in, or nil when it spans more than one.
    static func singleWeek(_ s: Summary) -> LocalDate? {
        let start = monday(of: s.from)
        return start == monday(of: s.to) ? start : nil
    }

    /// The ISO 8601 week number: the week that holds the Thursday. Recap captions read "Week 43".
    public static func isoWeek(_ date: LocalDate) -> Int {
        let thursday = monday(of: date).adding(days: 3)
        guard let jan1 = LocalDate(year: thursday.year, month: 1, day: 1) else { return 0 }
        return jan1.days(until: thursday) / 7 + 1
    }

    /// "Tue to Wed" inside one week, "27 to 28 Oct" otherwise, for one run of consecutive days; "on 3 days"
    /// when the days are not consecutive.
    static func onCallSpan(_ days: [LocalDate], weekNames: Bool) -> String {
        let sorted = days.sorted()
        guard let first = sorted.first, let last = sorted.last else { return "" }
        guard first.days(until: last) == sorted.count - 1 else { return "on \(count(sorted.count, "day"))" }
        func name(_ d: LocalDate) -> String {
            weekNames ? weekdayNames[Weekday.allCases.firstIndex(of: d.weekday) ?? 0] : "\(d.day) \(monthNames[d.month - 1])"
        }
        if first == last { return name(first) }
        if !weekNames && first.month == last.month && first.year == last.year {
            return "\(first.day) to \(name(last))"
        }
        return "\(name(first)) to \(name(last))"
    }
}
