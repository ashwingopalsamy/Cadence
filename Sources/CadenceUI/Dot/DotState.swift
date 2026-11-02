// The menu-bar dot's states and what each says to VoiceOver (docs/SPEC.md section 4.1).
import Foundation

public enum DotState: String, Sendable, CaseIterable, Equatable {
    case resting, dayStarted, planPending, inProgress, agentLogged, wrapUpDue, sealed, onCall, leave, paused, needsAttention
}

/// What the dot needs from outside the store. Each comes from the task that owns it: the plan prompt and wrap-up
/// reminders, the capture pause and the agent write signal. All default to off until those land.
public struct DotSignals: Sendable, Equatable {
    public var paused: Bool
    public var planPromptFired: Bool
    public var wrapUpDue: Bool
    public var agentLogged: Bool

    public init(paused: Bool = false, planPromptFired: Bool = false, wrapUpDue: Bool = false, agentLogged: Bool = false) {
        self.paused = paused
        self.planPromptFired = planPromptFired
        self.wrapUpDue = wrapUpDue
        self.agentLogged = agentLogged
    }
}

/// One moment of the dot: its state, plus what the form and the words need.
public struct DotAppearance: Sendable, Equatable {
    public var state: DotState
    /// Resolved over planned. Nil when nothing is planned.
    public var progress: Double?
    /// On call adds the outer ring to whatever else the day is.
    public var onCall: Bool
    public var resolved: Int
    public var planned: Int
    public var startedAt: Date?
    public var streak: Int?

    public init(
        state: DotState, progress: Double? = nil, onCall: Bool = false, resolved: Int = 0, planned: Int = 0,
        startedAt: Date? = nil, streak: Int? = nil
    ) {
        self.state = state
        self.progress = progress
        self.onCall = onCall
        self.resolved = resolved
        self.planned = planned
        self.startedAt = startedAt
        self.streak = streak
    }

    /// The form follows the first that applies. An error outranks everything, because the rest could not be read.
    public init(load: DayLoad, signals: DotSignals = DotSignals()) {
        switch load {
        case .loading:
            self.init(state: .resting)
        case .failed:
            self.init(state: .needsAttention)
        case .loaded(let day):
            let state: DotState
            if signals.paused {
                state = .paused
            } else if day.kind.isLeaveOrHoliday {
                state = .leave
            } else if day.isSealed {
                state = .sealed
            } else if day.kind == .weekend {
                state = .resting
            } else if signals.wrapUpDue {
                state = .wrapUpDue
            } else if signals.agentLogged {
                state = .agentLogged
            } else if day.planned > 0 {
                state = .inProgress
            } else if signals.planPromptFired {
                state = .planPending
            } else if day.startedAt != nil {
                state = .dayStarted
            } else if day.onCall {
                state = .onCall
            } else {
                state = .resting
            }
            self.init(
                state: state, progress: day.resolvedFraction, onCall: day.onCall, resolved: day.resolved,
                planned: day.planned, startedAt: day.startedAt, streak: day.streak?.current)
        }
    }

    /// The VoiceOver string. On call is said after whatever else is true.
    public func accessibilityLabel(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let label = stateLabel(locale: locale, timeZone: timeZone)
        return onCall && state != .onCall ? "\(label), on call" : label
    }

    private func stateLabel(locale: Locale, timeZone: TimeZone) -> String {
        switch state {
        case .resting: return "Cadence, day not started"
        case .dayStarted:
            guard let startedAt else { return "Day started" }
            let format = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
            return "Day started at \(startedAt.formatted(format))"
        case .planPending: return "Plan your day"
        case .inProgress: return "\(resolved) of \(planned) planned done"
        case .agentLogged: return "An agent logged work"
        case .wrapUpDue: return "Wrap-up due"
        case .sealed: return streak.map { "Day sealed, streak \($0)" } ?? "Day sealed"
        case .onCall: return "On call"
        case .leave: return "On leave"
        case .paused: return "Capture paused"
        case .needsAttention: return "Cadence needs attention"
        }
    }
}
