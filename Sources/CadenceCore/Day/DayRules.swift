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

    /// The last instant of a day's grace window: 23:59:59 local on the next calendar day ("wrap up yesterday until the
    /// end of today"). The window decides when an unsealed day stops being open, for reminders, "yesterday still
    /// open" and the streak. It does not decide whether a seal counts: any seal does, whenever it was made.
    public func graceEnd(of date: LocalDate, in zone: TimeZone) -> Date {
        Timestamp.resolve(date.adding(days: 2), hour: 0, minute: 0, in: zone).addingTimeInterval(-0.001)
    }

    /// Whether a leave or holiday that took effect at `declaredAt` (the recorded time of the declaration) came after
    /// the grace window of `date` had closed. Declared ahead, on the day or inside the window is on time. Only a day the
    /// configuration counts as a workday can be late: a holiday on a Saturday takes nothing out of any count.
    public func declaredLate(_ date: LocalDate, at declaredAt: Date, in zone: TimeZone) -> Bool {
        workdays.contains(date.weekday) && Self.milliseconds(declaredAt) > Self.milliseconds(graceEnd(of: date, in: zone))
    }

    /// Ledger times carry milliseconds. Comparing whole milliseconds keeps floating-point noise in a `Date` from
    /// pushing the last moment of a window past its end.
    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Whether the grace window for `date` has closed by `now`, so an unsealed day is final.
    public func graceClosed(for date: LocalDate, at now: Date, in zone: TimeZone) -> Bool {
        now > graceEnd(of: date, in: zone)
    }
}

extension SQLiteStore {
    /// The kind the latest `day.declared` gave `date`, if any. `days.kind` cannot answer this alone:
    /// it reads `workday` both by default and when a weekend was declared a workday.
    public func declaredKind(of date: LocalDate) throws(CadenceError) -> DayKind? {
        let declared = try readEvents(
            "SELECT * FROM events WHERE subject = ? AND type = 'day.declared' ORDER BY seq DESC LIMIT 1",
            [.text("day:\(date)")]
        ).first
        guard let declared, case .dayDeclared(let payload)? = try? EventPayload(type: declared.type, data: declared.data)
        else { return nil }
        return payload.kind
    }
}
