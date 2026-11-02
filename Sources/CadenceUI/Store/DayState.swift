import CadenceCore
import Foundation

/// Why the store could not be read. The words are for the person: the summary says what happened, the
/// detail says where and why. Neither holds anything that was in the log.
public struct StoreFailure: Sendable, Equatable {
    public var summary: String
    public var detail: String

    public init(summary: String = "Cadence cannot read its store", detail: String) {
        self.summary = summary
        self.detail = detail
    }

    init(_ error: CadenceError) {
        self.init(detail: error.message)
    }
}

/// Today as the menu-bar dot and the Pocket need it, read from the journal at one instant
/// (docs/SPEC.md sections 4.1, 4.2 and 5.2).
///
/// Every field is something the store said. What it could not say is nil, never 0 (section 6.6): a streak
/// that could not be worked out is nil, and a fraction with nothing planned is nil rather than 0 of 0.
public struct DayState: Sendable, Equatable {
    public var day: LocalDate
    public var kind: DayKind
    public var onCall: Bool
    /// The first activity of the day. Nil when none is recorded yet, which is a fact, not an unknown.
    public var startedAt: Date?
    /// When the day was sealed. Nil while it is not sealed.
    public var sealedAt: Date?
    /// The tasks that belong to the day, in plan order. A task carried to another day has left it, as in the ring.
    public var tasks: [PlanTask]
    /// The numbers behind the day ring: planned and resolved tasks, and the beads by family.
    public var ring: DayRing
    /// Nil when it could not be worked out. The rest of the state still stands.
    public var streak: Streak?

    public init(day: LocalDate, view: DayView, streak: Streak?) {
        self.day = day
        kind = view.day.kind
        onCall = view.day.onCall
        startedAt = view.day.firstActivity.flatMap { Timestamp.parse($0) }
        sealedAt = view.day.sealedAt.flatMap { Timestamp.parse($0) }
        tasks = view.tasks.filter { $0.status != .moved }
        ring = DayRing(view)
        self.streak = streak
    }

    public var isSealed: Bool { sealedAt != nil }

    /// Tasks planned for the day.
    public var planned: Int { ring.planned }

    /// Planned tasks that are done, slipped or dropped: the dot's arc counts every task you have settled.
    public var resolved: Int { ring.done + ring.slipped + ring.dropped }

    /// Resolved over planned, or nil when nothing is planned (there is no fraction of nothing).
    public var resolvedFraction: Double? {
        planned > 0 ? Double(resolved) / Double(planned) : nil
    }
}

/// What the model holds: nothing yet, a day, or the reason there is none. There is no state that
/// carries a day and a failure at once, so a failed read can never show old numbers as current.
public enum DayLoad: Sendable, Equatable {
    case loading
    case loaded(DayState)
    case failed(StoreFailure)
}
