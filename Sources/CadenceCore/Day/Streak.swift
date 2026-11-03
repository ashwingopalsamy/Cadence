import Foundation

/// The streak as docs/SPEC.md section 3 defines it: consecutive workdays that are sealed, whenever the seal was made.
/// Weekends, leave and holidays pause it and never break it.
public struct Streak: Sendable, Equatable {
    public var current: Int
    public var best: Int
    /// Leave and holiday days skipped inside the current run, oldest first.
    public var pausedBy: [LocalDate]
    /// A past workday is unsealed but still inside its grace window, so sealing it now keeps the run.
    public var atRisk: Bool

    public init(current: Int = 0, best: Int = 0, pausedBy: [LocalDate] = [], atRisk: Bool = false) {
        self.current = current
        self.best = best
        self.pausedBy = pausedBy
        self.atRisk = atRisk
    }

    public var json: JSONValue {
        [
            "current": .int(Int64(current)), "best": .int(Int64(best)),
            "paused_by": .array(pausedBy.map { .string($0.description) }), "at_risk": .bool(atRisk),
        ]
    }
}

extension DayRules {
    /// The seal instant and zone of each sealed day, keyed by date.
    public typealias SealedDays = [LocalDate: (sealedAt: Date, zone: TimeZone)]

    /// Pure streak computation over a ledger's days, from `first` through `asOf`.
    ///
    /// - A workday counts when it is sealed, whenever the seal was made, so a day sealed weeks late joins the runs on
    ///   both sides of it. A workday that is unsealed, including one reopened and not sealed again, breaks the run
    ///   once its grace window has closed at `now`; until then it is neither counted nor broken.
    /// - Weekends, leave and holidays never count and never break, sealed or not.
    /// - `now` is the reference instant, so a caller asking about a past day passes the end of that day.
    public func streak(
        sealed: SealedDays, declared: [LocalDate: DayKind], first: LocalDate, asOf: LocalDate, now: Date,
        zone: TimeZone
    ) -> Streak {
        guard first <= asOf else { return Streak() }
        var run = 0
        var best = 0
        var paused: [LocalDate] = []
        var atRisk = false
        for day in LocalDate.range(first, through: asOf) {
            let kind = self.kind(of: day, declared: declared[day])
            guard kind == .workday else {
                if run > 0, kind != .weekend { paused.append(day) }
                continue
            }
            let dayZone = sealed[day]?.zone ?? zone
            if sealed[day] != nil {
                run += 1
                best = max(best, run)
            } else if graceClosed(for: day, at: now, in: dayZone) {
                run = 0
                paused = []
            } else if day < asOf {
                atRisk = true
            }
        }
        return Streak(current: run, best: best, pausedBy: paused, atRisk: atRisk && run > 0)
    }

    /// The next day after `date` that counts as a workday, by weekday and declarations. Searches a year ahead
    /// and falls back to the next calendar day if the configuration leaves no workday at all.
    public func nextWorkday(after date: LocalDate, declared: [LocalDate: DayKind]) -> LocalDate {
        var day = date.adding(days: 1)
        for _ in 0..<366 {
            if kind(of: day, declared: declared[day]) == .workday { return day }
            day = day.adding(days: 1)
        }
        return date.adding(days: 1)
    }
}
