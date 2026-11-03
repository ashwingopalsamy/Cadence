/// Entry kinds and their families (docs/SPEC.md section 6.2, "Work families").
public enum EntryKind: String, Sendable, Hashable, CaseIterable, Codable {
    case prOpened = "pr.opened"
    case prMerged = "pr.merged"
    case shipped
    case workDone = "work.done"
    case reviewGiven = "review.given"
    case docReviewed = "doc.reviewed"
    case initiativeStarted = "initiative.started"
    case initiativeProgress = "initiative.progress"
    case incidentHandled = "incident.handled"
    case oncallShift = "oncall.shift"
    case discussionRaised = "discussion.raised"
    case decisionChallenged = "decision.challenged"
    case meetingLed = "meeting.led"
    case mentoring
    case docWritten = "doc.written"
    case genaiSession = "genai.session"
    case genaiUsage = "genai.usage"
    case presenceSpan = "presence.span"
    case meetingAttended = "meeting.attended"
    case note

    public var defaultFamily: Family {
        switch self {
        case .prOpened, .prMerged, .shipped, .workDone: .delivery
        case .reviewGiven, .docReviewed: .review
        case .initiativeStarted, .initiativeProgress: .initiative
        case .incidentHandled, .oncallShift: .ownership
        case .discussionRaised, .decisionChallenged, .meetingLed, .mentoring, .docWritten: .leadership
        case .genaiSession, .genaiUsage: .ai
        case .presenceSpan, .meetingAttended, .note: .presence
        }
    }

    /// Delivery kinds with a self-initiated ticket count as initiative work.
    public static func family(for kind: EntryKind, ticketClass: TicketClass?) -> Family {
        if kind.defaultFamily == .delivery, ticketClass == .selfInitiated { return .initiative }
        return kind.defaultFamily
    }
}
