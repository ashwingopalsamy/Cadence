import Foundation

/// One week of the Plan weeks and Reviews week bars (docs/SPEC.md section 5.4). The numbers are `Summary`'s, read over
/// the week clipped to the range, so a week and a summary of the same days can never disagree. A figure that is
/// unknown is nil and is never plotted as zero.
public struct WeekPoint: Sendable, Equatable {
    /// The Monday that starts the week. Weeks run Monday to Sunday.
    public var monday: LocalDate
    public var planDone: Int?
    public var planTotal: Int?
    public var mergedPRs: Int?
    public var reviews: Int?
    /// True when the week is not a whole, settled week: the range cut it short, it holds today, or it started before
    /// the ledger began. Plan weeks hatches these bars.
    public var partial: Bool
}

/// The usual start and end of one weekday (docs/SPEC.md section 5.4, Day shape).
public struct WeekdayShape: Sendable, Equatable {
    public var weekday: Weekday
    /// The median, earliest and latest first activity, with the number of days read. Nil when no workday on this weekday
    /// has one, which is unknown and not 00:00.
    public var firstActivity: ClockSpread?
    public var lastActivity: ClockSpread?
}

extension Journal {
    /// One point for every week that overlaps `from` through `to`, oldest first. Each point is `summary(from:to:)` over
    /// the week's days that fall inside the range. Read-only.
    public func weeklySeries(from: LocalDate, to: LocalDate) throws(CadenceError) -> [WeekPoint] {
        guard from <= to else { throw .validation("the range starts after it ends") }
        guard from.days(until: to) < Self.maxSummaryDays else {
            throw .validation("a series covers at most \(Self.maxSummaryDays) days; use a shorter range")
        }
        let today = self.today()
        // With no ledger start nothing has been recorded, so every week began before the ledger, as in `summary`.
        let ledgerStart = try self.ledgerStart()
        let first = Self.monday(onOrBefore: from)
        let weeks = first.days(until: Self.monday(onOrBefore: to)) / 7 + 1

        var points: [WeekPoint] = []
        for week in 0..<weeks {
            let monday = first.adding(days: 7 * week)
            let sunday = monday.adding(days: 6)
            let summary = try self.summary(from: max(monday, from), to: min(sunday, to))
            let clipped = monday < from || sunday > to
            let holdsToday = monday <= today && today <= sunday
            let beforeLedger = ledgerStart.map { monday < $0 } ?? true
            points.append(
                WeekPoint(
                    monday: monday, planDone: summary.planDone, planTotal: summary.planTotal, mergedPRs: summary.mergedPRs,
                    reviews: summary.reviews, partial: clipped || holdsToday || beforeLedger))
        }
        return points
    }

    private static func monday(onOrBefore date: LocalDate) -> LocalDate {
        date.adding(days: -(Weekday.allCases.firstIndex(of: date.weekday) ?? 0))  // Monday is index 0
    }

    /// The usual first and last activity for Monday to Friday over `from` through `to`. Only days that count as a workday
    /// (the configured workdays and what the user declared) contribute, so weekends, leave and holidays never move a
    /// median, and each day is read on the clock of the zone it was lived in. A workday declared on a Saturday or Sunday
    /// has no weekday here. Read-only.
    public func dayShape(from: LocalDate, to: LocalDate) throws(CadenceError) -> [WeekdayShape] {
        guard from <= to else { throw .validation("the range starts after it ends") }
        let rules = DayRules(config: config)
        let declared = try declaredKinds()
        var first: [Weekday: [ClockSpread.Reading]] = [:]
        var last: [Weekday: [ClockSpread.Reading]] = [:]
        let days = try rows(
            "SELECT date, tz, first_activity, last_activity FROM days WHERE date >= ? AND date <= ?",
            [.text(from.description), .text(to.description)])
        for row in days {
            guard let date = row.text("date").flatMap({ LocalDate($0) }),
                rules.kind(of: date, declared: declared[date]) == .workday
            else { continue }
            let dayZone = row.text("tz").flatMap { TimeZone(identifier: $0) } ?? zone
            if let reading = ClockSpread.reading(row.text("first_activity"), in: dayZone) {
                first[date.weekday, default: []].append(reading)
            }
            if let reading = ClockSpread.reading(row.text("last_activity"), in: dayZone) {
                last[date.weekday, default: []].append(reading)
            }
        }
        return [Weekday.mon, .tue, .wed, .thu, .fri].map { weekday in
            WeekdayShape(
                weekday: weekday, firstActivity: ClockSpread.over(first[weekday] ?? []),
                lastActivity: ClockSpread.over(last[weekday] ?? []))
        }
    }
}
