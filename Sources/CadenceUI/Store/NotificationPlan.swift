import CadenceCore
import Foundation

// What the app tells you and when (docs/SPEC.md section 4.7), as pure data: no UserNotifications, no clock, no store.
// `CadenceApp/Notifications.swift` turns these values into requests and hands the replies back.

/// The four categories the app registers. The raw value is the identifier the system sees.
public enum NotificationCategory: String, Sendable, CaseIterable {
    case plan = "PLAN"
    case wrap = "WRAP"
    case inbox = "INBOX"
    case source = "SOURCE"
}

/// A button on a notification. The raw value is the identifier of the action.
public enum NotificationAction: String, Sendable, CaseIterable {
    case planNow = "PLAN_NOW"
    case planLater = "PLAN_LATER"
    case planSkip = "PLAN_SKIP"
    case wrapUp = "WRAP_UP"
    case wrapLater = "WRAP_LATER"
    case openSources = "OPEN_SOURCES"

    public var title: String {
        switch self {
        case .planNow: String(localized: "Plan now")
        case .planLater, .wrapLater: String(localized: "In 30 min")
        case .planSkip: String(localized: "Skip today")
        case .wrapUp: String(localized: "Wrap up")
        case .openSources: String(localized: "Open Sources")
        }
    }

    public var category: NotificationCategory {
        switch self {
        case .planNow, .planLater, .planSkip: .plan
        case .wrapUp, .wrapLater: .wrap
        case .openSources: .source
        }
    }

    /// The buttons of a category, in the order of section 4.7. The inbox has none.
    public static func actions(for category: NotificationCategory) -> [NotificationAction] {
        allCases.filter { $0.category == category }
    }
}

/// Where a notification sends you, for the panel and the sheets to open. A tap goes where its main button goes.
public enum NotificationRoute: Sendable, Equatable {
    /// The morning plan sheet for the day.
    case plan(LocalDate)
    /// The wrap-up sheet for the day.
    case wrapUp(LocalDate)
    /// Sources, in Settings or the window.
    case sources
    case inbox
}

/// What the app does with a reply: open something, put the notification off once, or stop prompting today.
public enum NotificationReply: Sendable, Equatable {
    case route(NotificationRoute)
    /// "In 30 min": one new notification of the category, replacing an earlier put-off.
    case snooze(NotificationCategory, LocalDate)
    /// "Skip today": the plan prompt does not come back today.
    case skipToday(LocalDate)
}

/// What the person did to a notification.
public enum NotificationResponse: Sendable, Equatable {
    case tap
    case dismiss
    case action(String)
}

/// Whether the system lets the app show notifications. A denial is reported to the caller, which turns it into the
/// "Notifications are off" screen of section 4.6.
public enum NotificationAccess: Sendable, Equatable {
    case notDetermined
    case allowed
    case denied
}

/// One notification the app wants to exist. A `fireAt` is a calendar time in `zone`; no `fireAt` means now.
public struct PlannedNotification: Sendable, Equatable {
    public var id: String
    public var category: NotificationCategory
    /// The workday it is about. Nil for a notice about a source.
    public var day: LocalDate?
    public var title: String
    public var body: String
    public var fireAt: Date?
    public var zone: TimeZone

    public init(
        id: String, category: NotificationCategory, day: LocalDate?, title: String, body: String, fireAt: Date?, zone: TimeZone
    ) {
        self.id = id
        self.category = category
        self.day = day
        self.title = title
        self.body = body
        self.fireAt = fireAt
        self.zone = zone
    }

    /// The calendar time of the trigger in the profile zone, to the second, or nil for a notification that is due now.
    public var dateComponents: DateComponents? {
        guard let fireAt else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
        parts.calendar = calendar
        parts.timeZone = zone
        return parts
    }
}

/// What the app knows of today when it writes the words. Anything it could not read is nil, never 0.
public struct NotificationFacts: Sendable, Equatable {
    public var day: LocalDate
    public var committed: Bool
    public var sealed: Bool
    /// Titles of the tasks carried in and waiting to be planned.
    public var carried: [String]?
    /// Titles of the planned tasks still open.
    public var open: [String]?
    /// Items logged today.
    public var items: Int?
    /// Review requests waiting on the person, when a source says so.
    public var reviewsWaiting: Int?

    public init(
        day: LocalDate, committed: Bool = false, sealed: Bool = false, carried: [String]? = nil, open: [String]? = nil,
        items: Int? = nil, reviewsWaiting: Int? = nil
    ) {
        self.day = day
        self.committed = committed
        self.sealed = sealed
        self.carried = carried
        self.open = open
        self.items = items
        self.reviewsWaiting = reviewsWaiting
    }

    public init(state: DayState, reviewsWaiting: Int? = nil) {
        let context = state.context
        self.init(
            day: state.day, committed: context?.committed ?? false, sealed: state.isSealed,
            carried: context?.carried.map(\.title),
            open: (context?.plan ?? state.tasks).filter { $0.status == .open }.map(\.title),
            items: context?.rhythm.today, reviewsWaiting: reviewsWaiting)
    }
}

/// Everything the plan is worked out from.
public struct NotificationInput: Sendable, Equatable {
    public var now: Date
    /// The profile zone.
    public var zone: TimeZone
    public var rules: DayRules
    /// Leave, holidays and weekends declared workdays, for the days ahead.
    public var declared: [LocalDate: DayKind]
    public var reminders: [Config.Reminder]
    /// "Show task titles in notifications", off unless the person turned it on.
    public var showTitles: Bool
    /// Today as last read.
    public var facts: NotificationFacts?
    /// "In 30 min" requests still waiting.
    public var snoozed: [PlannedNotification]
    /// Days on which "Skip today" was pressed.
    public var skippedPlanDays: Set<LocalDate>

    public init(
        now: Date, zone: TimeZone, rules: DayRules, declared: [LocalDate: DayKind] = [:], reminders: [Config.Reminder],
        showTitles: Bool = false, facts: NotificationFacts? = nil, snoozed: [PlannedNotification] = [],
        skippedPlanDays: Set<LocalDate> = []
    ) {
        self.now = now
        self.zone = zone
        self.rules = rules
        self.declared = declared
        self.reminders = reminders
        self.showTitles = showTitles
        self.facts = facts
        self.snoozed = snoozed
        self.skippedPlanDays = skippedPlanDays
    }

    /// The workday `now` belongs to.
    public var today: LocalDate { rules.boundary.day(of: now, in: zone) }
}

/// What to change in the system's list of pending notifications.
public struct NotificationChanges: Sendable, Equatable {
    public var add: [PlannedNotification]
    public var remove: [String]

    public init(add: [PlannedNotification], remove: [String]) {
        self.add = add
        self.remove = remove
    }
}

public enum NotificationPlan {
    /// "Wrap-up triggers are rescheduled each morning for the next 7 workdays" (section 4.7).
    public static let workdaysAhead = 7
    public static let snoozeMinutes = 30
    /// A source is worth a notice after this many hours without a sync (section 4.6).
    public static let sourceThresholdHours = 3
    /// A day other than today has no counts yet, and a count read hours ago would be wrong by then.
    public static let unknownCountsBody = String(localized: "A minute to seal the day.")

    // MARK: What to schedule

    /// The next `count` workdays from `start`, skipping weekends, leave and holidays. A weekend declared a workday
    /// counts. Looks at most a year ahead, so a configuration with no workday at all ends instead of looping.
    public static func workdays(from start: LocalDate, count: Int, rules: DayRules, declared: [LocalDate: DayKind]) -> [LocalDate] {
        var found: [LocalDate] = []
        var day = start
        for _ in 0..<366 where found.count < count {
            if rules.kind(of: day, declared: declared[day]) == .workday { found.append(day) }
            day = day.adding(days: 1)
        }
        return found
    }

    /// One calendar notification for each wrap-up time of each of the next 7 workdays, still ahead. Today's carry
    /// its counts; the other days cannot, so they ask plainly. A day that is already sealed has none.
    public static func wrapReminders(_ input: NotificationInput) -> [PlannedNotification] {
        let times = Set(input.reminders.filter { $0.kind == .wrap }.compactMap(\.at)).filter { DayBoundary($0) != nil }.sorted()
        let today = input.today
        let facts = input.facts.flatMap { $0.day == today ? $0 : nil }
        var planned: [PlannedNotification] = []
        for day in workdays(from: today, count: workdaysAhead, rules: input.rules, declared: input.declared) {
            if day == today, facts?.sealed == true { continue }
            for time in times {
                guard let at = DayClockInput.instant(of: time, on: day, rules: input.rules, zone: input.zone), at > input.now else { continue }
                planned.append(
                    PlannedNotification(
                        id: "wrap.\(day).\(time)", category: .wrap, day: day, title: String(localized: "Wrap up \(name(of: day)), \(time)"),
                        body: day == today ? wrapBody(facts, titles: input.showTitles) : unknownCountsBody, fireAt: at,
                        zone: input.zone))
            }
        }
        return planned
    }

    /// Everything that should be pending: the wrap-up reminders and the put-offs still wanted.
    public static func scheduled(_ input: NotificationInput) -> [PlannedNotification] {
        let kept = input.snoozed.filter { wanted($0, input) }
        return (wrapReminders(input) + kept).sorted {
            ($0.fireAt ?? .distantPast, $0.id) < ($1.fireAt ?? .distantPast, $1.id)
        }
    }

    /// "Plan Thursday", due now, or nil when today needs no prompt: it is not a workday, the plan is committed, the day
    /// is sealed, "Skip today" was pressed, or today has not been read.
    public static func planPrompt(_ input: NotificationInput) -> PlannedNotification? {
        let today = input.today
        guard let facts = input.facts, facts.day == today,
            input.rules.kind(of: today, declared: input.declared[today]) == .workday,
            !facts.committed, !facts.sealed, !input.skippedPlanDays.contains(today)
        else { return nil }
        return PlannedNotification(
            id: "plan.\(today)", category: .plan, day: today, title: String(localized: "Plan \(name(of: today))"),
            body: planBody(facts, titles: input.showTitles), fireAt: nil, zone: input.zone)
    }

    /// "In 30 min": the same notification once more, `snoozeMinutes` from now. It has one fixed identifier per
    /// category and day, so pressing the button again replaces the earlier put-off and never adds another. Nil when
    /// there is nothing left to put off.
    public static func snooze(_ category: NotificationCategory, day: LocalDate, input: NotificationInput) -> PlannedNotification? {
        let at = input.now.addingTimeInterval(TimeInterval(snoozeMinutes * 60))
        let facts = input.facts.flatMap { $0.day == day ? $0 : nil }
        switch category {
        case .plan:
            guard let facts, !facts.committed, !facts.sealed, !input.skippedPlanDays.contains(day) else { return nil }
            return PlannedNotification(
                id: "plan.\(day).later", category: .plan, day: day, title: String(localized: "Plan \(name(of: day))"),
                body: planBody(facts, titles: input.showTitles), fireAt: at, zone: input.zone)
        case .wrap:
            guard facts?.sealed != true else { return nil }
            return PlannedNotification(
                id: "wrap.\(day).later", category: .wrap, day: day,
                title: String(localized: "Wrap up \(name(of: day)), \(Timestamp.clockTime(at, in: input.zone))"),
                body: wrapBody(facts, titles: input.showTitles), fireAt: at, zone: input.zone)
        case .inbox, .source:
            return nil
        }
    }

    /// "GitHub has not synced for 3 hours", due now, or nil before the threshold.
    public static func sourceBehind(source: String, hours: Int) -> PlannedNotification? {
        guard hours >= sourceThresholdHours else { return nil }
        return PlannedNotification(
            id: "source.\(source)", category: .source, day: nil, title: String(localized: "\(source) has not synced for \(noun(hours, String(localized: "hour")))"),
            body: String(localized: "Everything else keeps working."), fireAt: nil, zone: .current)
    }

    /// Whole hours between the last good sync and now, never negative.
    public static func hoursBehind(since lastSync: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(lastSync) / 3600))
    }

    /// What to add and remove so the pending list becomes `desired`. An item whose words or time did not change is
    /// left alone, so a busy day does not rewrite the list at every item logged.
    public static func changes(from current: [PlannedNotification], to desired: [PlannedNotification]) -> NotificationChanges {
        let have = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let want = Set(desired.map(\.id))
        return NotificationChanges(
            add: desired.filter { have[$0.id] != $0 }, remove: current.map(\.id).filter { !want.contains($0) })
    }

    // MARK: What a reply does

    /// What to do about a tap or a button, from the category and the day the notification carried. Nil for a dismissal,
    /// a button that is not the category's, or a day that is missing where one is needed.
    public static func reply(category: String, response: NotificationResponse, day: String?) -> NotificationReply? {
        guard let category = NotificationCategory(rawValue: category) else { return nil }
        let day = day.flatMap { LocalDate($0) }
        switch response {
        case .dismiss:
            return nil
        case .tap:
            switch category {
            case .plan: return day.map { .route(.plan($0)) }
            case .wrap: return day.map { .route(.wrapUp($0)) }
            case .source: return .route(.sources)
            case .inbox: return .route(.inbox)
            }
        case .action(let identifier):
            guard let action = NotificationAction(rawValue: identifier), action.category == category else { return nil }
            switch action {
            case .planNow: return day.map { .route(.plan($0)) }
            case .planLater: return day.map { .snooze(.plan, $0) }
            case .planSkip: return day.map { .skipToday($0) }
            case .wrapUp: return day.map { .route(.wrapUp($0)) }
            case .wrapLater: return day.map { .snooze(.wrap, $0) }
            case .openSources: return .route(.sources)
            }
        }
    }

    // MARK: Words

    /// "2 carried, and 1 review waiting on you". Counts only, unless titles are on: "2 carried (Write ADR and Review RFC)".
    static func planBody(_ facts: NotificationFacts, titles: Bool) -> String {
        var parts: [String] = []
        if let carried = facts.carried, !carried.isEmpty {
            parts.append(String(localized: "\(carried.count) carried") + listing(carried, show: titles))
        }
        if let reviews = facts.reviewsWaiting, reviews > 0 {
            parts.append(String(localized: "\(noun(reviews, String(localized: "review"))) waiting on you"))
        }
        return parts.isEmpty ? String(localized: "Nothing carried over.") : parts.joined(separator: ", and ")
    }

    /// "2 tasks open, and 7 items logged". What could not be read is left out, not written as 0.
    static func wrapBody(_ facts: NotificationFacts?, titles: Bool) -> String {
        var parts: [String] = []
        if let open = facts?.open {
            parts.append(String(localized: "\(noun(open.count, String(localized: "task"))) open") + listing(open, show: titles))
        }
        if let items = facts?.items {
            parts.append(String(localized: "\(noun(items, String(localized: "item"))) logged"))
        }
        return parts.isEmpty ? unknownCountsBody : parts.joined(separator: ", and ")
    }

    /// " (A and B)", " (A, B and 3 more)", or nothing when titles are off.
    private static func listing(_ titles: [String], show: Bool) -> String {
        guard show, !titles.isEmpty else { return "" }
        let shown = titles.prefix(2).map(clip)
        let rest = titles.count - shown.count
        if rest > 0 { return String(localized: " (\(shown.joined(separator: ", ")) and \(rest) more)") }
        return " (\(shown.joined(separator: " and ")))"
    }

    /// One line of at most 40 characters: whitespace and line breaks collapse, a long title ends in an ellipsis.
    private static func clip(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > 40 else { return line }
        return String(line.prefix(39)) + "\u{2026}"
    }

    private static func noun(_ count: Int, _ singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }

    private static func name(of day: LocalDate) -> String {
        switch day.weekday {
        case .mon: "Monday"
        case .tue: "Tuesday"
        case .wed: "Wednesday"
        case .thu: "Thursday"
        case .fri: "Friday"
        case .sat: "Saturday"
        case .sun: "Sunday"
        }
    }

    /// A put-off is wanted until it is due, its day is sealed, or its plan is made or skipped.
    private static func wanted(_ snooze: PlannedNotification, _ input: NotificationInput) -> Bool {
        guard let at = snooze.fireAt, at > input.now else { return false }
        let facts = input.facts.flatMap { $0.day == snooze.day ? $0 : nil }
        switch snooze.category {
        case .wrap:
            return facts?.sealed != true
        case .plan:
            if let day = snooze.day, input.skippedPlanDays.contains(day) { return false }
            return facts.map { !$0.committed && !$0.sealed } ?? true
        case .inbox, .source:
            return false
        }
    }
}
