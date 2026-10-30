/// Who produced a record. Set once, never changes.
public enum Origin: String, Sendable, Hashable, CaseIterable, Codable {
    case observed, collected, agent
    case selfReported = "self"
}

public enum EntryStatus: String, Sendable, Hashable, CaseIterable, Codable {
    case proposed, accepted, dismissed, deleted
}

public enum DayKind: String, Sendable, Hashable, CaseIterable, Codable {
    case workday, weekend, holiday
    case leavePlanned = "leave_planned"
    case leaveUnplanned = "leave_unplanned"

    public var isLeaveOrHoliday: Bool {
        switch self {
        case .holiday, .leavePlanned, .leaveUnplanned: true
        case .workday, .weekend: false
        }
    }
}

public enum PlanOrigin: String, Sendable, Hashable, CaseIterable, Codable {
    case selfReported = "self"
    case suggested, carried
}

public enum TaskStatus: String, Sendable, Hashable, CaseIterable, Codable {
    case open, done, slipped, dropped, moved

    /// Counts toward plan versus done: done, slipped and dropped. Open and moved tasks do not.
    public var isResolved: Bool {
        switch self {
        case .done, .slipped, .dropped: true
        case .open, .moved: false
        }
    }
}

public enum TicketClass: String, Sendable, Hashable, CaseIterable, Codable {
    case assigned
    case selfInitiated = "self"
}

public enum ExportPolicy: String, Sendable, Hashable, CaseIterable, Codable {
    case include, digest, exclude
}

public enum PresenceSource: String, Sendable, Hashable, CaseIterable, Codable {
    case input, wake, unlock, powerlog, manual
}

public enum LinkKind: String, Sendable, Hashable, CaseIterable, Codable {
    case pr, ticket, doc, other
}

public enum Weekday: String, Sendable, Hashable, CaseIterable, Codable {
    case mon, tue, wed, thu, fri, sat, sun
}

public enum Family: String, Sendable, Hashable, CaseIterable, Codable {
    case delivery, review, initiative, ownership, leadership, ai, presence

    /// The fixed order of ring beads (docs/SPEC.md section 5.2). Presence has no bead.
    public static let ringOrder: [Family] = [.delivery, .review, .initiative, .ownership, .leadership, .ai]
}
