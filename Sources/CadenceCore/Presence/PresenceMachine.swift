import Foundation

/// What the Mac tells the presence engine (docs/SPEC.md section 8.4). Each event happens at the instant the
/// engine's clock reads when it is handed over.
public enum PresenceEvent: Sendable, Equatable {
    /// An idle sample: seconds since the last keyboard or pointer input of any kind, and whether the session is
    /// unlocked and on the console. Input while locked is the lock screen, not work.
    case sample(idleSeconds: Double, unlocked: Bool)
    case wake
    case sleep
    case lock
    case unlock
    /// Fast user switching brought this session back.
    case sessionActive
    /// Fast user switching moved to another session.
    case sessionResigned
    /// Logout, restart or shutdown.
    case powerOff
    /// The engine stops (the app quits). Closes like sleep; the next launch starts afresh.
    case stop
}

/// The thresholds of section 8.4.
public struct PresenceRules: Sendable, Equatable, Codable {
    /// A sample is input when the idle time is under this.
    public var activeIdle: Double
    /// A span closes once the idle time reaches this; it is also the longest gap between two events that is not
    /// a clock jump or missed time.
    public var closeIdle: Double

    public static let standard = PresenceRules(activeIdle: 5, closeIdle: 300)

    public init(activeIdle: Double, closeIdle: Double) {
        self.activeIdle = activeIdle
        self.closeIdle = closeIdle
    }
}

/// One workday as the engine needs it: its date, the zone it is read in and where it starts.
public struct PresenceDay: Sendable, Equatable {
    public var day: LocalDate
    public var zone: TimeZone
    public var start: Date

    public init(day: LocalDate, zone: TimeZone, start: Date) {
        self.day = day
        self.zone = zone
        self.start = start
    }
}

/// Places an instant on a workday. The Journal's calendar honours each day's own zone; tests use a fixed one.
public protocol PresenceCalendar {
    func workday(of instant: Date) -> PresenceDay
}

/// One zone, one boundary.
public struct FixedPresenceCalendar: PresenceCalendar, Sendable {
    public let zone: TimeZone
    public let boundary: DayBoundary

    public init(zone: TimeZone, boundary: DayBoundary) {
        self.zone = zone
        self.boundary = boundary
    }

    public func workday(of instant: Date) -> PresenceDay {
        let day = boundary.day(of: instant, in: zone)
        return PresenceDay(day: day, zone: zone, start: boundary.interval(of: day, in: zone).start)
    }
}

/// What the machine asks to be written.
public enum PresenceOutput: Sendable, Equatable {
    /// A closed stretch of presence. It may still cross a day boundary; the writer cuts it.
    case span(start: Date, end: Date, source: PresenceSource)
    /// The first input of a workday as the machine saw it. The writer skips it when the day already started.
    case dayStarted(day: LocalDate, zone: TimeZone, at: Date)
}

/// The presence state machine of section 8.4: pure, deterministic, and small enough to save between launches.
///
/// - A sample with idle under 5 s while unlocked is input at `t - idle`. With no open span it opens one there,
///   carrying `wake` or `unlock` when that event came since the last span, otherwise `input`.
/// - A sample with idle of 300 s or more closes the open span at `t - idle`, the last input, not at detection.
/// - Sleep, power off, lock, session resign and stop close the open span at the event's time, or at the last
///   input when that was already 5 minutes or more before it. Wake and unlock open nothing; the next input does.
/// - Input on a later workday than the open span's start writes the part before that day's start and carries
///   on from that input, so yesterday's last activity is known as soon as the boundary passes. The first input of each
///   workday asks for `day.started`.
/// - A clock that goes backwards, or a gap of more than 5 minutes between two events (a forward jump, a missed
///   wake, a crash), closes the open span at the last input seen before it. What happened in between is unknown.
public struct PresenceMachine: Sendable, Equatable, Codable {
    public var rules: PresenceRules
    /// Start of the open span.
    var open: Date?
    var openSource: PresenceSource?
    /// The latest input seen while the span is open.
    var lastInput: Date?
    /// The time of the last event handled, to see the clock jump.
    var lastTime: Date?
    var locked: Bool
    var asleep: Bool
    /// The source the next span opens with.
    var pending: PresenceSource
    /// The workday the machine last asked to start, "YYYY-MM-DD".
    var startedDay: String?

    public init(rules: PresenceRules = .standard) {
        self.rules = rules
        locked = false
        asleep = false
        pending = .input
    }

    public var isOpen: Bool { open != nil }

    public mutating func handle(_ event: PresenceEvent, at t: Date, calendar: some PresenceCalendar) -> [PresenceOutput] {
        var out: [PresenceOutput] = []
        if let last = lastTime, t < last || t.timeIntervalSince(last) > rules.closeIdle {
            out += close(at: lastInput ?? open ?? last)
        }
        lastTime = t

        switch event {
        case .sample(let idle, let unlocked):
            guard idle.isFinite, idle >= 0 else { break }
            if asleep {
                // Samples are only taken while the Mac is awake, so a wake was missed.
                asleep = false
                pending = .wake
            }
            guard unlocked else {
                if !locked {
                    out += closeForEvent(at: t, calendar: calendar)
                    locked = true
                }
                break
            }
            if locked {
                locked = false
                pending = .unlock
            }
            let input = t.addingTimeInterval(-idle)
            if open != nil, input > (lastInput ?? input.addingTimeInterval(-1)) {
                // Newer input counts even when it is only seen through a longer idle, so yesterday ends at the boundary.
                out += rollOver(to: input, calendar: calendar)
                lastInput = input
            }
            if open != nil, idle >= rules.closeIdle {
                out += close(at: input)
                break
            }
            guard idle < rules.activeIdle else { break }
            if open == nil {
                open = input
                openSource = pending
                pending = .input
                lastInput = input
            }
            out += markStarted(calendar.workday(of: input), at: input)

        case .sleep, .powerOff:
            out += closeForEvent(at: t, calendar: calendar)
            asleep = true
        case .lock, .sessionResigned:
            out += closeForEvent(at: t, calendar: calendar)
            locked = true
        case .wake:
            if asleep || open == nil {
                asleep = false
                pending = .wake
            }
        case .unlock, .sessionActive:
            if locked {
                locked = false
                pending = .unlock
            }
        case .stop:
            out += closeForEvent(at: t, calendar: calendar)
        }
        return out
    }

    /// Closes for an event at `t`: at `t`, unless the last input was already a close's worth of idle before it. A last
    /// input on an earlier workday closes at the boundary: no input means no presence on the new day.
    private mutating func closeForEvent(at t: Date, calendar: some PresenceCalendar) -> [PresenceOutput] {
        guard let input = lastInput else { return close(at: t) }
        if t.timeIntervalSince(input) >= rules.closeIdle { return close(at: input) }
        let day = calendar.workday(of: t)
        if calendar.workday(of: input).day != day.day { return close(at: min(t, day.start)) }
        return close(at: t)
    }

    /// Input on a later workday writes the part before that day's start, and the new piece starts at the input itself.
    private mutating func rollOver(to input: Date, calendar: some PresenceCalendar) -> [PresenceOutput] {
        let day = calendar.workday(of: input)
        guard let start = open, calendar.workday(of: start).day != day.day else { return [] }
        let cut = min(max(day.start, start), input)
        open = input
        var out: [PresenceOutput] = cut > start ? [.span(start: start, end: cut, source: openSource ?? .input)] : []
        out += markStarted(day, at: input)
        return out
    }

    /// The first input of a workday asks for `day.started`, once.
    private mutating func markStarted(_ day: PresenceDay, at input: Date) -> [PresenceOutput] {
        guard startedDay != day.day.description else { return [] }
        startedDay = day.day.description
        return [.dayStarted(day: day.day, zone: day.zone, at: input)]
    }

    private mutating func close(at end: Date) -> [PresenceOutput] {
        guard let start = open else { return [] }
        let source = openSource ?? .input
        open = nil
        openSource = nil
        lastInput = nil
        return end > start ? [.span(start: start, end: end, source: source)] : []
    }
}
