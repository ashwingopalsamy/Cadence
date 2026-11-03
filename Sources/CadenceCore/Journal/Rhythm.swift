import Foundation

/// The middle 50% of a count over your own recent days, with the median as its dividing line (docs/SPEC.md
/// section 5.1). A fact about a count, never a goal. `days` is how many days it was computed from.
public struct UsualRange: Sendable, Equatable {
    public var low: Int
    public var median: Int
    public var high: Int
    public var days: Int

    /// The most days a range reads: the last 20.
    public static let windowDays = 20
    /// Under this many days there is no range, and Cadence says it is still learning.
    public static let minimumDays = 10

    public init(low: Int, median: Int, high: Int, days: Int) {
        self.low = low
        self.median = median
        self.high = high
        self.days = days
    }

    /// The 25th, 50th and 75th percentiles of the last 20 of `values` (oldest first, so the cap keeps the recent ones),
    /// by linear interpolation between ranks at `(n - 1) * p`, each rounded half away from zero. Nil under 10 values.
    public static func of(_ values: [Int]) -> UsualRange? {
        let recent = values.suffix(windowDays).sorted()
        guard recent.count >= minimumDays else { return nil }
        return UsualRange(
            low: percentile(recent, 0.25), median: percentile(recent, 0.5), high: percentile(recent, 0.75),
            days: recent.count)
    }

    /// `sorted` is ascending and not empty. A rank is a multiple of a quarter, so every step here is exact in a `Double`
    /// and a value that lands on a half is a true half.
    private static func percentile(_ sorted: [Int], _ p: Double) -> Int {
        let rank = Double(sorted.count - 1) * p
        let lower = Int(rank.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let value = Double(sorted[lower]) + Double(sorted[upper] - sorted[lower]) * (rank - Double(lower))
        return Int(value.rounded(.toNearestOrAwayFromZero))
    }
}

/// Today read against the bracket: above its high is more than usual, below its low is fewer, otherwise in rhythm.
public enum Pace: Sendable, Equatable {
    case fewer, usual, more

    public static func of(_ count: Int, against range: UsualRange) -> Pace {
        if count > range.high { return .more }
        if count < range.low { return .fewer }
        return .usual
    }
}

/// One date of the band chart. `items` is nil when the date is not a counted workday (a gap, never a zero) and
/// `usual` is the range as it stood on that date, from the counted workdays before it only.
public struct RhythmPoint: Sendable, Equatable {
    public var date: LocalDate
    public var items: Int?
    public var usual: UsualRange?

    public init(date: LocalDate, items: Int?, usual: UsualRange?) {
        self.date = date
        self.items = items
        self.usual = usual
    }
}

/// What is usual, and what is usual by now (docs/SPEC.md sections 5.1 and 5.2). Every range is nil under 10 days.
public struct Rhythm: Sendable, Equatable {
    /// Items logged on the reference day, whatever kind of day it is. A leave day or a weekend is a state of its own,
    /// which ranks above this comparison.
    public var today: Int
    /// The usual day: over the last 20 counted workdays before the reference day.
    public var usual: UsualRange?
    /// The same days read at the same time of day, so a day in progress is not compared with whole ones.
    public var byNow: UsualRange?
    /// Tasks planned per day over the last 20 planned workdays before the reference day.
    public var plan: UsualRange?
    /// The window of dates ending at the reference day, oldest first.
    public var points: [RhythmPoint]

    public init(today: Int, usual: UsualRange?, byNow: UsualRange?, plan: UsualRange?, points: [RhythmPoint]) {
        self.today = today
        self.usual = usual
        self.byNow = byNow
        self.plan = plan
        self.points = points
    }

    /// Today against the by-now bracket. Nil when there is no bracket yet. A stale source suppresses this too, and that is
    /// the caller's to know (docs/SPEC.md section 5.1).
    public var pace: Pace? { byNow.map { Pace.of(today, against: $0) } }
}

extension DayBoundary {
    /// Minutes from the day boundary to the wall-clock time of `instant` in `zone`: 0 at the boundary, 1439 a minute before
    /// the next one. So with a 04:00 boundary 01:00 is 1260, late in the day and not early.
    func minutesSinceBoundary(_ instant: Date, in zone: TimeZone) -> Int {
        let minuteOfDay = LocalDate.floorMod(Timestamp.localSeconds(instant, in: zone), 86_400) / 60
        return LocalDate.floorMod(minuteOfDay - (hour * 60 + minute), 24 * 60)
    }
}

extension Journal {
    static let maxRhythmWindow = 366

    /// Items logged: accepted entries that are neither presence nor AI. A row is one item, as `summary` counts entries.
    static let itemsWhere = "status = 'accepted' AND family NOT IN ('presence', 'ai')"

    /// The usual range read model for `day` (default: the day `instant` belongs to) as of `instant` (default: now), with
    /// a window of `window` dates ending at `day`. Read-only.
    ///
    /// A counted workday is a workday with at least one item logged; leave, holidays, weekends and days with nothing are
    /// gaps. Only days strictly before `day` are read. A day is measured in its own zone (the one its `days` row carries),
    /// and `instant` in the zone of `day`. Entries with no `occurred_at` count toward a full day and never toward by now.
    /// A planned workday has at least one task that is not moved and was not added after the seal.
    public func rhythm(on day: LocalDate? = nil, at instant: Date? = nil, window: Int = 28) throws(CadenceError) -> Rhythm {
        guard (1...Self.maxRhythmWindow).contains(window) else {
            throw .validation("window: a rhythm covers 1 to \(Self.maxRhythmWindow) days")
        }
        let instant = instant ?? clock.now()
        let day = day ?? config.dayBoundary.day(of: instant, in: zone)
        let key = SQLValue.text(day.description)
        let rules = DayRules(config: config)
        let declared = try declaredKinds()

        // Items per day up to the reference day, then the counted workdays among them, oldest first.
        var itemsByDay: [LocalDate: Int] = [:]
        for row in try rows(
            "SELECT day, COUNT(*) AS n FROM entries WHERE \(Self.itemsWhere) AND day <= ? GROUP BY day", [key])
        {
            if let date = row.text("day").flatMap({ LocalDate($0) }), let n = row.int("n") { itemsByDay[date] = Int(n) }
        }
        let counted = itemsByDay.filter { rules.kind(of: $0.key, declared: declared[$0.key]) == .workday }
            .map { (date: $0.key, items: $0.value) }
            .sorted { $0.date < $1.date }
        let countedItems = Dictionary(uniqueKeysWithValues: counted.map { ($0.date, $0.items) })
        let values = counted.map(\.items)

        /// The usual day as it stood on `date`: from the counted workdays before it.
        func band(before date: LocalDate) -> UsualRange? {
            let end = counted.firstIndex { $0.date >= date } ?? counted.count
            return UsualRange.of(Array(values[..<end].suffix(UsualRange.windowDays)))
        }

        // Usual by now: the same last days, each cut at the same time of day measured in its own zone.
        let prior = Array(counted.prefix(while: { $0.date < day }).suffix(UsualRange.windowDays))
        var byNow: UsualRange?
        if prior.count >= UsualRange.minimumDays, let first = prior.first {
            let from = SQLValue.text(first.date.description)
            var zones: [String: TimeZone] = [:]
            for row in try rows("SELECT date, tz FROM days WHERE date >= ? AND date <= ?", [from, key]) {
                if let date = row.text("date"), let id = row.text("tz"), let tz = TimeZone(identifier: id) { zones[date] = tz }
            }
            let boundary = config.dayBoundary
            let now = boundary.minutesSinceBoundary(instant, in: zones[day.description] ?? zone)
            var byNowByDay: [LocalDate: Int] = [:]
            for row in try rows(
                "SELECT day, occurred_at FROM entries WHERE \(Self.itemsWhere) AND occurred_at IS NOT NULL AND day >= ? AND day < ?",
                [from, key])
            {
                guard let text = row.text("day"), let date = LocalDate(text),
                    let at = row.text("occurred_at").flatMap({ Timestamp.parse($0) })
                else { continue }
                if boundary.minutesSinceBoundary(at, in: zones[text] ?? zone) <= now { byNowByDay[date, default: 0] += 1 }
            }
            byNow = UsualRange.of(prior.map { byNowByDay[$0.date] ?? 0 })
        }

        // Usual plan size: tasks planned per day on workdays that had a plan, as a wrap-up counts them.
        var planned: [Int] = []
        for row in try rows(
            """
            SELECT day, COUNT(*) AS n FROM plan_tasks
            WHERE status != 'moved' AND \(Self.taskAfterSealSQL) = 0 AND day < ? GROUP BY day ORDER BY day
            """,
            [key])
        {
            guard let date = row.text("day").flatMap({ LocalDate($0) }), let n = row.int("n"),
                rules.kind(of: date, declared: declared[date]) == .workday
            else { continue }
            planned.append(Int(n))
        }

        let points = (0..<window).map { offset -> RhythmPoint in
            let date = day.adding(days: offset - (window - 1))
            return RhythmPoint(date: date, items: countedItems[date], usual: band(before: date))
        }
        return Rhythm(today: itemsByDay[day] ?? 0, usual: band(before: day), byNow: byNow, plan: UsualRange.of(planned), points: points)
    }
}
