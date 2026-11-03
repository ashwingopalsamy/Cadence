import CadenceCore
import Foundation

/// What the Log is narrowed to (docs/SPEC.md section 4.6): free text over titles, tickets and notes, one work kind and
/// one origin. Each chip row picks one value or none, as the prototype's filters do, and the three compose with AND.
public struct LogFilter: Sendable, Equatable {
    public var search: String
    public var family: Family?
    public var origin: Origin?

    public init(search: String = "", family: Family? = nil, origin: Origin? = nil) {
        self.search = search
        self.family = family
        self.origin = origin
    }

    /// The work kinds offered as chips, in the order of the ring. Presence and notes are reached through All.
    public static let families: [Family] = Family.ringOrder
    /// The origins offered as chips (docs/SPEC.md section 2).
    public static let origins: [Origin] = [.observed, .collected, .agent, .selfReported]

    /// The searched text as the query takes it: trimmed, and nil when blank.
    public var searchText: String? {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Nothing narrows the Log.
    public var isClear: Bool { searchText == nil && family == nil && origin == nil }

    /// The query for days `from` through `to`. The Log shows accepted entries: proposals wait in the Inbox and count
    /// for nothing until accepted. The app is the person's own surface, so search also looks inside notes
    /// (docs/decisions/README.md, T3.27).
    public func query(from: LocalDate, to: LocalDate, cursor: String? = nil, limit: Int = EntryQuery.maxLimit) -> EntryQuery {
        EntryQuery(
            from: from, to: to, families: family.map { [$0] } ?? [], origins: origin.map { [$0] } ?? [],
            statuses: [.accepted], search: searchText, searchNotes: true, cursor: cursor, limit: limit)
    }
}

/// One page of the Log, newest first. Pages are whole days, so a day never splits across two pages.
public struct LogPage: Sendable, Equatable {
    public var entries: [Entry]
    /// The day the next page ends before, or nil when there is nothing older.
    public var before: LocalDate?
    /// The journal's today, for the "Today" heading.
    public var today: LocalDate
    /// The profile's zone, for the times in an entry's history.
    public var zone: TimeZone
    /// The seals and reopenings of the days on the page that were reopened, by day. A day sealed once or never is not here.
    public var histories: [String: [DayHistoryItem]]

    public init(entries: [Entry], before: LocalDate?, today: LocalDate, zone: TimeZone, histories: [String: [DayHistoryItem]] = [:]) {
        self.entries = entries
        self.before = before
        self.today = today
        self.zone = zone
        self.histories = histories
    }

    /// A page holds at least this many entries, unless there are fewer.
    public static let pageTarget = 60
    /// A page walks back this many days at a time.
    public static let windowDays = 14

    /// The first and last days a query can name.
    static let earliestDay = LocalDate(year: 1000, month: 1, day: 1)!
    static let latestDay = LocalDate(year: 9999, month: 12, day: 31)!

    /// Reads one page. `Journal.query` runs oldest first, so the page walks back in windows of `windowDays`, reading each
    /// window whole and reversing it, until it holds at least `target` entries or reaches the oldest match. The first
    /// window reaches past today, so an entry dated ahead still shows.
    public static func read(
        _ journal: Journal, filter: LogFilter, before: LocalDate?, target: Int = pageTarget, windowDays: Int = windowDays
    ) throws(CadenceError) -> LogPage {
        let today = journal.today()
        let oldest = try journal.query(filter.query(from: earliestDay, to: latestDay, limit: 1)).entries.first
            .flatMap { LocalDate($0.day) }
        guard let oldest else { return LogPage(entries: [], before: nil, today: today, zone: journal.zone) }
        var end = before?.adding(days: -1) ?? latestDay
        var found: [Entry] = []
        while found.count < target, end >= oldest {
            let from = max(oldest, min(end, today).adding(days: -(windowDays - 1)))
            var window: [Entry] = []
            var cursor: String?
            repeat {
                let page = try journal.query(filter.query(from: from, to: end, cursor: cursor))
                window += page.entries
                cursor = page.next
            } while cursor != nil
            found += window.reversed()
            end = from.adding(days: -1)
        }
        var histories: [String: [DayHistoryItem]] = [:]
        for day in Set(found.map(\.day)) {
            guard let date = LocalDate(day) else { continue }
            let history = try journal.dayHistory(date)
            if history.contains(where: { $0.kind == .reopened }) { histories[day] = history }
        }
        return LogPage(
            entries: found, before: end >= oldest ? end.adding(days: 1) : nil, today: today, zone: journal.zone,
            histories: histories)
    }
}
