import Foundation

/// The local time at which one workday ends and the next begins (default 04:00).
public struct DayBoundary: Sendable, Hashable {
    public let hour: Int
    public let minute: Int

    public static let standard = DayBoundary(unchecked: 4, 0)

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// "HH:MM", 00:00...23:59.
    public init?(_ text: String) {
        guard let (h, m) = Timestamp.parseClock(text) else { return nil }
        self.init(hour: h, minute: m)
    }

    private init(unchecked hour: Int, _ minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// The workday an instant belongs to in `zone`: the local calendar date, minus one day if the local
    /// time is before the boundary.
    public func day(of instant: Date, in zone: TimeZone) -> LocalDate {
        let local = Timestamp.localSeconds(instant, in: zone)
        let days = LocalDate.floorDiv(local, 86_400)
        let secs = LocalDate.floorMod(local, 86_400)
        let date = LocalDate.fromEpochDays(days)
        return secs < hour * 3600 + minute * 60 ? date.adding(days: -1) : date
    }

    /// [start, end) of a workday in `zone`. In a spring-forward gap the first instant after the gap is used;
    /// in a fall-back overlap the first occurrence.
    public func interval(of day: LocalDate, in zone: TimeZone) -> (start: Date, end: Date) {
        (
            Timestamp.resolve(day, hour: hour, minute: minute, in: zone),
            Timestamp.resolve(day.adding(days: 1), hour: hour, minute: minute, in: zone)
        )
    }
}
