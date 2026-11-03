// Today as values (docs/SPEC.md sections 4.6, 5.1 and 5.2). Everything the page shows is decided here, from one read
// of the day, so every state can be built and tested without a store or a window. The views only lay it out.
import CadenceCore
import Foundation

/// What Today reads, at one instant.
public struct TodayInput: Sendable, Equatable {
    /// The day as the story reads it: counts, flags and what only the app knows.
    public var day: DayStory.Input
    public var zone: TimeZone
    public var now: Date
    /// Dates follow the system locale (section 6.6).
    public var locale: Locale
    public var firstActivity: Date?
    public var lastActivity: Date?
    /// The day's plan in plan order, and the tasks carried in while it is not committed.
    public var plan: [PlanTask]
    public var carried: [PlanTask]
    /// Accepted entries of the day, oldest first.
    public var found: [Entry]
    /// Nil when the store could not say.
    public var rhythm: Rhythm?
    /// Why the store could not be read, when that is the state.
    public var failure: StoreFailure.Kind?
    /// This week's sealed workdays, for days off. Nil when it is not known, which shows as "-".
    public var week: WeekSeals?
    /// A tick waiting out its Undo already reads as done.
    public var pendingTask: String?
    public var discreet: Bool
    /// Tempo is on in Settings. Discreet mode hides it as well.
    public var tempoEnabled: Bool
    /// An earlier day, shown read only. Nil is the live day.
    public var past: Past?

    /// An earlier day stepped back to with `←` (section 4.8).
    public struct Past: Sendable, Equatable {
        /// The day is still inside its grace window, so it keeps "Wrap up Wednesday".
        public var graceOpen: Bool

        public init(graceOpen: Bool = false) { self.graceOpen = graceOpen }
    }

    public init(
        day: DayStory.Input, zone: TimeZone, now: Date, locale: Locale = .current, firstActivity: Date? = nil,
        lastActivity: Date? = nil, plan: [PlanTask] = [], carried: [PlanTask] = [], found: [Entry] = [],
        rhythm: Rhythm? = nil, failure: StoreFailure.Kind? = nil, week: WeekSeals? = nil, pendingTask: String? = nil,
        discreet: Bool = false, tempoEnabled: Bool = true, past: Past? = nil
    ) {
        self.day = day
        self.zone = zone
        self.now = now
        self.locale = locale
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.plan = plan
        self.carried = carried
        self.found = found
        self.rhythm = rhythm
        self.failure = failure
        self.week = week
        self.pendingTask = pendingTask
        self.discreet = discreet
        self.tempoEnabled = tempoEnabled
        self.past = past
    }

    /// The one story every surface tells.
    public var story: DayStory { DayStory(day) }
    public var state: DayStory.State { story.state }
}

/// Sealed workdays this week, Monday first.
public struct WeekSeals: Sendable, Equatable {
    public var sealed: Int
    public var workdays: Int

    public init(sealed: Int, workdays: Int) {
        self.sealed = sealed
        self.workdays = workdays
    }
}

extension TodayInput {
    /// Today as the app holds it now, or nil before the first read. When `days` shows an earlier day, that day as it
    /// was last read, without what only the app knows now: pausing, a source behind and an import describe today.
    @MainActor public init?(app: AppState, days: DayBrowser? = nil) {
        let now = app.now
        let shown = days?.shown(today: app.today)
        var day: DayStory.Input
        var zone = TimeZone.current
        var failure: StoreFailure.Kind?
        var context: DayContext?
        var state: DayState?
        switch shown == nil ? app.model.load : days?.load ?? .loading {
        case .loading:
            return nil
        case .failed(let read):
            day = DayStory.Input(date: shown ?? app.today)
            if read.kind == .missing, shown == nil { day.firstRun = true } else { day.storeProblem = true }
            failure = read.kind
        case .loaded(let loaded):
            state = loaded
            context = loaded.context
            zone = loaded.context.flatMap { TimeZone(identifier: $0.zone) } ?? .current
            day = loaded.context?.storyInput(at: now) ?? DayStory.Input(date: loaded.day)
            if shown == nil {
                day.paused = app.signals.paused
                day.behind = app.signals.behind
                day.importing = app.signals.importing
                day.firstRun = !app.signals.setupFinished
            }
        }
        // Only the live day knows whether the last workday is still inside its grace window.
        let previous = app.context?.previous
        let past = shown.map { _ in Past(graceOpen: previous?.graceOpen == true && previous?.date == day.date) }
        self.init(
            day: day, zone: zone, now: now, firstActivity: state?.startedAt,
            lastActivity: context?.view.day.lastActivity.flatMap { Timestamp.parse($0) }, plan: context?.plan ?? [],
            carried: context?.carried ?? [], found: context?.found ?? [], rhythm: context?.rhythm, failure: failure,
            week: context.map { WeekSeals(sealed: $0.weekSealed, workdays: $0.weekWorkdays) },
            pendingTask: shown == nil ? app.pendingTick?.task : nil, discreet: app.discreet, tempoEnabled: app.tempoEnabled,
            past: past)
    }
}

// MARK: - What the page shows

/// Which arrangement of cards the day gets (section 4.6).
public enum TodayLayout: Sendable, Equatable {
    /// First run: the hero and the setup, which arrives with T4.12.
    case firstRun
    /// The hero and the failure card for what went wrong.
    case storeProblem(FailureCopy)
    /// This week's sealed days and a log field.
    case dayOff
    /// Nothing planned and nothing found: carried tasks or "You have not planned today yet".
    case unplanned
    /// The plan, the four metric cards, Found today and Log something.
    case full
}

/// What sits at the bottom of the hero.
public enum HeroChart: Sendable, Equatable {
    /// Items logged per workday against the usual range.
    case band
    /// Progress dots toward a range: 10 workdays while learning, 20 while the first sync runs.
    case learning(done: Int, of: Int, caption: String)
    /// The same height, empty.
    case none
}

/// The day's main actions, in the order they are shown; the last one is primary.
public enum TodayAction: Sendable, Equatable {
    case planYourDay
    case planToday
    case wrapUp
    case wrapUpYesterday(String)
    case seeRecap
    case notWorking
    /// A choice inside "Not working today": leave, sick or holiday.
    case dayOff(DayStory.DayOff)
    case sealEmpty

    public var title: String {
        switch self {
        case .planYourDay: String(localized: "Plan your day")
        case .planToday: String(localized: "Plan today")
        case .wrapUp: String(localized: "Wrap up")
        case .wrapUpYesterday(let day): String(localized: "Wrap up \(day)")
        case .seeRecap: String(localized: "See last week's recap")
        case .notWorking: String(localized: "Not working today")
        case .dayOff(let off): StatusMenuItem.daysOff.first { $0.0 == off }?.1 ?? String(localized: "Leave")
        case .sealEmpty: String(localized: "Seal as empty")
        }
    }

    /// Quiet actions sit on `track`; the primary is `ink`.
    public var isQuiet: Bool {
        switch self {
        case .seeRecap, .notWorking, .dayOff, .planToday: true
        default: false
        }
    }
}

/// A number with its small unit, as the numeral role sets it.
public struct MetricPart: Sendable, Equatable {
    public var number: String
    public var unit: String

    public init(_ number: String, _ unit: String = "") {
        self.number = number
        self.unit = unit
    }

    /// Unknown is "-", never 0 (section 6.6).
    public static let unknown = [MetricPart("-")]
}

/// One metric card: the four card slots in order, then a picture and its table twin.
public struct TodayMetric: Sendable, Equatable {
    public enum Picture: Sendable, Equatable {
        /// One square per item, in the family's colour.
        case blocks(Family, Int)
        /// First activity to now, as the share of the bar it fills.
        case span(Double?)
        /// Counts by family, as words beside a colour.
        case legend([LegendItem])
    }

    public struct LegendItem: Sendable, Equatable {
        public var family: Family
        public var text: String
    }

    public var label: String
    public var sentence: String
    public var value: [MetricPart]
    public var comparison: String
    public var picture: Picture
    /// The table twin. Empty when the picture is words already.
    public var rows: [[String]]
    /// What VoiceOver reads for the card.
    public var voice: String
}

extension TodayInput {
    public var world: ColorWorld { TodayWorld.world(for: state) }

    public var layout: TodayLayout {
        switch state {
        case .firstRun: return .firstRun
        case .storeProblem: return .storeProblem(FailureCopy(failure ?? .other))
        case .leave, .sick, .holiday, .weekend: return .dayOff
        default: return plan.isEmpty && shownFound.isEmpty ? .unplanned : .full
        }
    }

    /// The bottom of the hero. Days off, first run, nothing logged and a store problem have none.
    public var heroChart: HeroChart {
        let learning = DayStory.learningDays
        switch state {
        case .learning:
            let done = min(day.countedWorkdays, learning)
            return .learning(done: done, of: learning, caption: String(localized: "\(done) of \(learning) workdays until your usual range appears"))
        case .firstSync:
            let window = UsualRange.windowDays
            let i = day.importing
            return .learning(done: min(i?.done ?? 0, window), of: window, caption: String(localized: "\(i?.label ?? String(localized: "History")) backfill"))
        case .leave, .sick, .holiday, .weekend, .firstRun, .nothingLogged, .storeProblem:
            return .none
        default:
            if band != nil { return .band }
            if day.countedWorkdays < learning {
                return .learning(
                    done: day.countedWorkdays, of: learning,
                    caption: String(localized: "\(day.countedWorkdays) of \(learning) workdays until your usual range appears"))
            }
            return .none
        }
    }

    /// "Thursday 29 Oct, first activity 09:41, on call".
    public var kicker: String {
        var parts = [TodayFormat.longDate(day.date, locale: locale)]
        if let start = firstActivity { parts.append(String(localized: "first activity \(clock(start))")) }
        if day.onCall { parts.append(String(localized: "on call")) }
        return parts.joined(separator: ", ")
    }

    /// The forest world's night sky, on sealed days.
    public var showsStars: Bool { world.name == CadenceWorld.forest.name }

    /// A source feeding the count is behind: the sentence ends with "Check Sources".
    public var showsCheckSources: Bool { state == .sourceBehind }

    /// Tempo shows when it is on and discreet mode is off.
    public var showsTempo: Bool { tempoEnabled && !discreet }

    public var tempo: TempoSpec { TempoSpec.compose(state: state, input: day, hour: hour) }

    /// What the last workday holds, for its card: "4 of 5 planned done, 8 items logged" and how many are still open.
    public var yesterdaySummary: (line: String, detail: String)? {
        guard past == nil, let previous = day.previous, previous.graceOpen, day.sealedAt == nil, day.dayOff == nil else { return nil }
        let name = TodayFormat.weekday(previous.date)
        var parts: [String] = []
        if previous.planned > 0 { parts.append(String(localized: "\(previous.done) of \(previous.planned) planned done")) }
        parts.append(String(localized: "\(previous.items) \(previous.items == 1 ? String(localized: "item") : String(localized: "items")) logged"))
        let open = previous.planned - previous.done
        let detail = open > 0
            ? String(localized: "\(open) \(open == 1 ? String(localized: "task is") : String(localized: "tasks are")) still open. Sealing takes under a minute.")
            : String(localized: "Sealing takes under a minute.")
        return ("\(name): " + parts.joined(separator: ", "), detail)
    }

    /// "Wrap up Wednesday" when the last workday is still open.
    public var yesterday: String? {
        guard past == nil, let previous = day.previous, previous.graceOpen, day.sealedAt == nil, day.dayOff == nil else { return nil }
        return TodayFormat.weekday(previous.date)
    }

    /// The day's main actions. The last is primary.
    public var actions: [TodayAction] {
        switch layout {
        case .firstRun, .storeProblem, .dayOff: return []
        case .unplanned, .full: break
        }
        // An earlier day is read only. Inside its grace window it can still be wrapped up.
        if let past {
            return past.graceOpen && day.sealedAt == nil ? [.wrapUpYesterday(TodayFormat.weekday(day.date))] : []
        }
        if day.sealedAt != nil { return [.seeRecap] }
        if !plan.isEmpty { return [.wrapUp] }
        if state == .nothingLogged { return [.notWorking, .sealEmpty] }
        if state == .yesterdayOpen { return [.planToday] }
        return [.planYourDay]
    }

    /// The headline of the card when nothing is planned or found.
    public var unplannedTitle: String {
        if past != nil { return String(localized: "Nothing planned or logged") }
        if !carried.isEmpty { return String(localized: "Pick up where you left off") }
        if state == .nothingLogged { return String(localized: "Nothing planned or logged") }
        return String(localized: "You have not planned today yet")
    }

    /// What VoiceOver reads for the hero.
    public var heroVoice: String {
        let story = story
        guard past == nil else { return String(localized: "Showing \(kicker). \(story.headline) \(story.sentence)") }
        return "\(kicker). \(story.headline) \(story.sentence)"
    }

    /// Found today, or the weekday's name on an earlier day.
    public var foundLabel: String {
        past == nil ? String(localized: "Found today") : String(localized: "Found on \(TodayFormat.weekday(day.date))")
    }

    // MARK: Tasks and found items

    /// A task's status as the page shows it: a tick waiting for Undo reads as done.
    public func status(of task: PlanTask) -> TaskStatus {
        pendingTask == task.id ? .done : task.status
    }

    public var shownDone: Int { plan.filter { status(of: $0) == .done }.count }

    /// A title as the page may show it: "Task 1" and "Item 1" in discreet mode, as `AppState.title` does.
    public func title(_ text: String, index: Int, word: String = String(localized: "Item")) -> String {
        discreet ? "\(word) \(index + 1)" : text
    }

    /// Ticket keys are hidden in discreet mode.
    public func ticket(_ task: PlanTask) -> String? { discreet ? nil : task.ticket?.key }

    /// What a slipped task shows beside it: the chip's words, or the reason as typed.
    public func reason(_ task: PlanTask) -> String? {
        guard status(of: task) == .slipped else { return nil }
        guard let reason = task.reason, !reason.isEmpty else { return String(localized: "Slipped") }
        return SlipReason(stored: reason)?.label ?? (discreet ? String(localized: "Slipped") : reason)
    }

    /// Entries Found today lists: everything accepted except presence spans, newest first.
    public var shownFound: [Entry] {
        found.filter { $0.family != .presence }.reversed()
    }

    /// The first link of an entry the system can open, for its row's link button.
    func link(of entry: Entry) -> LinkTarget? {
        entry.linkTargets(discreet: discreet).first { $0.url != nil }
    }

    /// The local time an entry happened, or "-".
    public func time(of entry: Entry) -> String {
        entry.occurredAt.flatMap { Timestamp.parse($0) }.map(clock) ?? "-"
    }

    // MARK: Metrics

    /// The plan card's number: done over planned, "-" with nothing planned.
    public var planValue: [MetricPart] {
        plan.isEmpty ? MetricPart.unknown : [MetricPart(String(localized: "\(shownDone) of \(plan.count)"))]
    }

    public var planVoice: String {
        plan.isEmpty ? String(localized: "Your plan. Nothing planned yet.") : String(localized: "Your plan. \(shownDone) of \(plan.count) done.")
    }

    /// Delivery, Reviews, Day length and Beyond the plan, in that order.
    public var metrics: [TodayMetric] { [delivery, reviews, dayLength, beyondThePlan] }

    var delivery: TodayMetric {
        let merged = count(kind: .prMerged)
        let all = count(family: .delivery)
        let other = all - merged
        let rows = [EntryKind.prMerged, .prOpened, .shipped, .workDone].compactMap { kind -> [String]? in
            let n = count(kind: kind)
            return n > 0 ? [TodayFormat.kindName(kind), bound(n)] : nil
        }
        let value = countValue(merged, String(localized: "PR"), String(localized: "PRs"))
        return TodayMetric(
            label: String(localized: "Delivery"), sentence: String(localized: "You have merged"), value: value,
            comparison: other > 0
                ? String(localized: "Plus \(bound(other)) opened, shipped or done")
                : past == nil ? String(localized: "Merged pull requests today") : String(localized: "Merged pull requests that day"),
            picture: .blocks(.delivery, merged), rows: rows, voice: String(localized: "Delivery. You have merged \(spoken(value))."))
    }

    var reviews: TodayMetric {
        let n = count(family: .review)
        let rows = [EntryKind.reviewGiven, .docReviewed].compactMap { kind -> [String]? in
            let c = count(kind: kind)
            return c > 0 ? [TodayFormat.kindName(kind), bound(c)] : nil
        }
        let value = countValue(n, String(localized: "review"), String(localized: "reviews"))
        return TodayMetric(
            label: String(localized: "Reviews"), sentence: String(localized: "You have given"), value: value, comparison: past == nil ? String(localized: "Code and document reviews today") : String(localized: "Code and document reviews that day"),
            picture: .blocks(.review, n), rows: rows, voice: String(localized: "Reviews. You have given \(spoken(value))."))
    }

    var dayLength: TodayMetric {
        // A sealed day and an earlier day both ended at their last activity, not now.
        let sealed = day.sealedAt != nil || past != nil
        let end = sealed ? (lastActivity ?? (past == nil ? now : firstActivity ?? now)) : now
        let minutes = firstActivity.map { max(0, Int(end.timeIntervalSince($0) / 60)) }
        let value: [MetricPart]
        if let minutes, minutes > 0 {
            value = [MetricPart("\(minutes / 60)", "h"), MetricPart(String(format: "%02d", minutes % 60), "m")]
        } else {
            value = MetricPart.unknown
        }
        let share = minutes.map { min(TodayGeometry.spanMax, Double($0) / TodayFormat.spanMinutes) }
        var rows: [[String]] = []
        if let start = firstActivity {
            rows = [
                [String(localized: "First activity"), clock(start)], [sealed ? String(localized: "Last activity") : String(localized: "Now"), clock(end)],
                [String(localized: "Length"), value.map { $0.number + $0.unit }.joined(separator: " ")],
            ]
        }
        return TodayMetric(
            label: String(localized: "Day length"), sentence: sealed ? String(localized: "First to last activity") : String(localized: "First activity to now"), value: value,
            comparison: firstActivity.map { String(localized: "From \(clock($0))") }
                ?? (past == nil ? String(localized: "Starts with your first input") : String(localized: "No activity recorded")), picture: .span(share),
            rows: rows, voice: String(localized: "Day length. \(minutes.map { String(localized: "\($0 / 60) hours \($0 % 60) minutes") } ?? String(localized: "Not known yet"))."))
    }

    var beyondThePlan: TodayMetric {
        let led = count(family: .leadership)
        let owned = count(family: .ownership)
        let started = count(family: .initiative)
        let n = led + owned + started
        let legend = [(Family.leadership, led, String(localized: "led")), (.ownership, owned, String(localized: "on call")), (.initiative, started, String(localized: "self-started"))]
            .filter { $0.1 > 0 }
            .map { TodayMetric.LegendItem(family: $0.0, text: "\(bound($0.1)) \($0.2)") }
        let ai = day.aiSessions
        let value = countValue(n, String(localized: "other thing"), String(localized: "other things"))
        return TodayMetric(
            label: String(localized: "Beyond the plan"), sentence: String(localized: "You also logged"), value: value,
            comparison: ai > 0 ? String(localized: "And \(DayStoryWords.count(ai, String(localized: "Claude Code session")))") : String(localized: "Meetings, mentoring and incidents"),
            picture: .legend(legend), rows: [], voice: String(localized: "Beyond the plan. You also logged \(spoken(value))."))
    }

    /// The days-off card: this week's sealed workdays.
    public var weekValue: [MetricPart] {
        guard let week, week.workdays > 0 else { return MetricPart.unknown }
        return [MetricPart("\(week.sealed)", String(localized: "of \(DayStoryWords.count(week.workdays, String(localized: "workday")))"))]
    }

    // MARK: Helpers

    var hour: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.component(.hour, from: now)
    }

    func clock(_ date: Date) -> String { Timestamp.clockTime(date, in: zone) }

    func count(family: Family) -> Int { found.filter { $0.family == family }.count }
    func count(kind: EntryKind) -> Int { found.filter { $0.kind == kind }.count }

    /// A source feeding the count is behind, so every count is a lower bound (section 6.6).
    var isLowerBound: Bool { day.behind != nil }

    func bound(_ n: Int) -> String { isLowerBound ? "≥\(n)" : "\(n)" }

    /// Nothing recorded is "-", never 0.
    func countValue(_ n: Int, _ one: String, _ many: String) -> [MetricPart] {
        n > 0 ? [MetricPart(bound(n), n == 1 ? one : many)] : MetricPart.unknown
    }

    func spoken(_ value: [MetricPart]) -> String {
        value == MetricPart.unknown ? String(localized: "nothing recorded yet") : value.map { "\($0.number) \($0.unit)" }.joined(separator: " ")
    }
}

/// The hero's colour world for each day state (section 6.2).
public enum TodayWorld {
    public static func world(for state: DayStory.State) -> ColorWorld {
        switch state {
        case .firstRun, .firstSync, .learning: CadenceWorld.lilac
        case .morning, .planned: CadenceWorld.butter
        case .inRhythm, .moreThanUsual: CadenceWorld.coral
        case .fewerThanUsual, .weekend: CadenceWorld.sage
        case .planSettled: CadenceWorld.mint
        case .wrapUpDue: CadenceWorld.rose
        case .sealed, .editedAfterWrapUp: CadenceWorld.forest
        case .yesterdayOpen, .closedUnsealed: CadenceWorld.plum
        case .onCall: CadenceWorld.teal
        case .leave, .sick, .holiday: CadenceWorld.sky
        case .paused, .sourceBehind, .nothingLogged: CadenceWorld.stone
        case .storeProblem: CadenceWorld.ink
        }
    }
}

/// Counts in words, as the story writes them.
enum DayStoryWords {
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

enum TodayFormat {
    /// A day this long fills the day-length bar to its end.
    static let spanMinutes = 600.0

    /// "Thursday 29 Oct" in the system locale.
    static func longDate(_ date: LocalDate, locale: Locale) -> String { format(date, "EEEEdMMM", locale) }

    /// "29 Oct" in the system locale.
    static func shortDate(_ date: LocalDate, locale: Locale) -> String { format(date, "dMMM", locale) }

    private static func format(_ date: LocalDate, _ template: String, _ locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate(template)
        // Midday UTC of the date, read in UTC, so no zone can move it to another day.
        let days = LocalDate(year: 1970, month: 1, day: 1).map { $0.days(until: date) } ?? 0
        let instant = Date(timeIntervalSince1970: Double(days) * 86_400 + 43_200)
        return formatter.string(from: instant)
    }

    /// The weekday's name, as the story writes it.
    static func weekday(_ date: LocalDate) -> String {
        switch date.weekday {
        case .mon: "Monday"
        case .tue: "Tuesday"
        case .wed: "Wednesday"
        case .thu: "Thursday"
        case .fri: "Friday"
        case .sat: "Saturday"
        case .sun: "Sunday"
        }
    }

    static func kindName(_ kind: EntryKind) -> String {
        switch kind {
        case .prMerged: String(localized: "Merged")
        case .prOpened: String(localized: "Opened")
        case .shipped: String(localized: "Shipped")
        case .workDone: String(localized: "Done")
        case .reviewGiven: String(localized: "Code reviews")
        case .docReviewed: String(localized: "Document reviews")
        default: kind.rawValue
        }
    }
}
