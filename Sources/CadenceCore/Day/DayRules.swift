import Foundation

/// The read-time rules for days that depend on config (docs/SPEC.md sections 3 and 4.5). Projections
/// store only what events say; these rules turn that into what a day counts as.
public struct DayRules: Sendable, Equatable {
    public var workdays: Set<Weekday>
    public var boundary: DayBoundary

    public init(workdays: Set<Weekday> = [.mon, .tue, .wed, .thu, .fri], boundary: DayBoundary = .standard) {
        self.workdays = workdays
        self.boundary = boundary
    }

    public init(config: Config) {
        self.init(workdays: Set(config.workdays), boundary: config.dayBoundary)
    }

    /// What a day counts as: the kind a `day.declared` gave it, otherwise workday or weekend by the
    /// configured workdays.
    public func kind(of date: LocalDate, declared: DayKind?) -> DayKind {
        declared ?? (workdays.contains(date.weekday) ? .workday : .weekend)
    }

    /// The last instant a day can be sealed and still count: 23:59:59 local on the next calendar day
    /// (the grace window, "seal yesterday until the end of today").
    public func graceEnd(of date: LocalDate, in zone: TimeZone) -> Date {
        Timestamp.resolve(date.adding(days: 2), hour: 0, minute: 0, in: zone).addingTimeInterval(-0.001)
    }

    /// Whether a seal recorded at `sealedAt` counts for `date`.
    public func sealCounts(_ sealedAt: Date, for date: LocalDate, in zone: TimeZone) -> Bool {
        sealedAt <= graceEnd(of: date, in: zone)
    }

    /// Whether the grace window for `date` has closed by `now`, so an unsealed day is final.
    public func graceClosed(for date: LocalDate, at now: Date, in zone: TimeZone) -> Bool {
        now > graceEnd(of: date, in: zone)
    }
}
