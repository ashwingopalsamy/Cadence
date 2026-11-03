import AppKit
import CadenceCore
import Dispatch
import Foundation
import Observation

/// A moment at which what the surfaces show can change, and why.
public struct DayMoment: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The next workday begins (04:00 by default).
        case boundary
        /// The day's plan prompt is due: day start plus the reminder's offset.
        case planPrompt
        /// A wrap-up reminder time of today, "HH:MM".
        case wrapReminder(String)
        /// The grace window of the last unsealed workday has closed, so that day is final.
        case graceClosed(LocalDate)
    }

    public var at: Date
    public var kind: Kind

    public init(at: Date, kind: Kind) {
        self.at = at
        self.kind = kind
    }
}

/// Everything the clock needs to work out the moments ahead (docs/SPEC.md section 3). Pure data: no clock, no
/// store, no AppKit, so the schedule is the same on every machine and tests feed it any instant.
public struct DayClockInput: Sendable, Equatable {
    /// The profile zone: workdays, reminders and grace windows are all read in it.
    public var zone: TimeZone
    /// The workdays and the day boundary.
    public var rules: DayRules
    /// What `day.declared` made of a day: leave, a holiday, or a weekend declared a workday.
    public var declared: [LocalDate: DayKind]
    /// The reminder list of the profile: plan prompts and wrap-up times.
    public var reminders: [Config.Reminder]
    /// The first activity of the current workday, or nil while it has not started.
    public var dayStartedAt: Date?
    /// The last unsealed workday whose grace window may still be open, or nil.
    public var unsealed: LocalDate?

    public init(
        zone: TimeZone, rules: DayRules, declared: [LocalDate: DayKind] = [:], reminders: [Config.Reminder],
        dayStartedAt: Date? = nil, unsealed: LocalDate? = nil
    ) {
        self.zone = zone
        self.rules = rules
        self.declared = declared
        self.reminders = reminders
        self.dayStartedAt = dayStartedAt
        self.unsealed = unsealed
    }

    /// The workday an instant belongs to.
    public func day(at instant: Date) -> LocalDate {
        rules.boundary.day(of: instant, in: zone)
    }

    /// The moments strictly after `now` that change what the surfaces show, earliest first:
    ///
    /// - the next boundary, always;
    /// - today's wrap-up times still ahead, and the plan prompt once the day has started, but only when today
    ///   counts as a workday: leave, a holiday and an undeclared weekend never prompt (section 3);
    /// - the close of the grace window of the last unsealed workday.
    ///
    /// Nothing past the next boundary is scheduled: the boundary reads the day again and schedules the next one.
    public func moments(after now: Date) -> [DayMoment] {
        let today = day(at: now)
        var end = rules.boundary.interval(of: today, in: zone).end
        if end <= now { end = rules.boundary.interval(of: today.adding(days: 1), in: zone).end }

        var found: [DayMoment] = []
        if rules.kind(of: today, declared: declared[today]) == .workday {
            for reminder in reminders {
                switch reminder.kind {
                case .wrap:
                    guard let time = reminder.at, let instant = Self.instant(of: time, on: today, rules: rules, zone: zone) else { continue }
                    found.append(DayMoment(at: instant, kind: .wrapReminder(time)))
                case .plan:
                    // A prompt for a day that has not started would greet someone who is not there.
                    guard let started = dayStartedAt, day(at: started) == today else { continue }
                    if let offset = reminder.after.flatMap(Self.offset) {
                        found.append(DayMoment(at: started.addingTimeInterval(offset), kind: .planPrompt))
                    } else if let time = reminder.at, let instant = Self.instant(of: time, on: today, rules: rules, zone: zone) {
                        found.append(DayMoment(at: instant, kind: .planPrompt))
                    }
                }
            }
        }
        found = found.filter { $0.at > now && $0.at < end }
        if let unsealed {
            // `graceEnd` is the last instant the window is open; the window is closed from the next millisecond.
            let close = rules.graceEnd(of: unsealed, in: zone).addingTimeInterval(0.001)
            if close > now { found.append(DayMoment(at: close, kind: .graceClosed(unsealed))) }
        }
        found.append(DayMoment(at: end, kind: .boundary))
        return Array(Set(found)).sorted(by: Self.inOrder)
    }

    /// "HH:MM" on a workday. A time before the boundary is the tail of the workday, so it falls on the next calendar date.
    static func instant(of time: String, on day: LocalDate, rules: DayRules, zone: TimeZone) -> Date? {
        guard let clock = DayBoundary(time) else { return nil }
        let before = (clock.hour, clock.minute) < (rules.boundary.hour, rules.boundary.minute)
        return Timestamp.instant(clockTime: time, on: before ? day.adding(days: 1) : day, in: zone)
    }

    /// "dayStart+2m" or "dayStart+1h" as seconds, or nil when it is not that.
    static func offset(_ text: String) -> TimeInterval? {
        let prefix = "dayStart+"
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        guard let unit = rest.last, unit == "m" || unit == "h" else { return nil }
        let digits = rest.dropLast()
        guard (1...4).contains(digits.utf8.count), digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
            let count = Int(digits), count > 0
        else { return nil }
        return TimeInterval(count * (unit == "h" ? 3600 : 60))
    }

    /// By time, then a fixed order, so two moments at the same instant always come out the same way.
    private static func inOrder(_ a: DayMoment, _ b: DayMoment) -> Bool {
        if a.at != b.at { return a.at < b.at }
        return rank(a.kind) < rank(b.kind)
    }

    private static func rank(_ kind: DayMoment.Kind) -> String {
        switch kind {
        case .planPrompt: return "0"
        case .wrapReminder(let time): return "1" + time
        case .graceClosed(let day): return "2" + day.description
        case .boundary: return "3"
        }
    }
}

extension DayClockInput {
    /// The input from the config and the day the model last read. With no state yet there is no start, no
    /// declaration and nothing unsealed: the clock still keeps the boundary and the reminders.
    public init(config: Config, state: DayState?) {
        var declared: [LocalDate: DayKind] = [:]
        var unsealed: LocalDate?
        if let state {
            // The kind the day reads as is what `kind(of:declared:)` returns for it, so it stands in for the declaration.
            declared[state.day] = state.kind
            if let previous = state.context?.previous, previous.graceOpen { unsealed = previous.date }
        }
        self.init(
            zone: TimeZone(identifier: config.profile.timezone) ?? .current, rules: DayRules(config: config),
            declared: declared, reminders: config.reminders, dayStartedAt: state?.startedAt, unsealed: unsealed)
    }

    /// As `init(config:state:)`, reading `config.json` where the store is. The file is a few hundred bytes. If it
    /// is missing or unreadable the defaults stand in; the day read reports the problem, and the clock keeps the
    /// standard boundary until the next read.
    public init(location: StoreLocation, state: DayState?) {
        let fallback = TimeZone.current.identifier
        var config = Config.defaults(timezone: fallback)
        if case .found(let roots) = location, let loaded = try? ConfigStore.load(from: roots.config, fallbackZone: fallback) {
            config = loaded.0
        }
        self.init(config: config, state: state)
    }
}

/// Sets one timer. The seam that keeps the clock testable without waiting.
@MainActor
public protocol DayClockTimer: AnyObject {
    /// Calls `handler` once at `date`, replacing anything armed before. `now` is the caller's present.
    func arm(at date: Date, now: Date, handler: @escaping @MainActor () -> Void)
    func cancel()
}

/// One `DispatchSourceTimer` on the wall clock, so a deadline that passes while the Mac sleeps goes off on wake.
/// A second of leeway lets the system coalesce it with other wake-ups.
@MainActor
public final class WallClockTimer: DayClockTimer {
    private var source: DispatchSourceTimer?

    public init() {}

    public func arm(at date: Date, now: Date, handler: @escaping @MainActor () -> Void) {
        cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        // Never sooner than 10 ms, so a moment a millisecond away cannot spin.
        let seconds = max(date.timeIntervalSince(now), 0.01)
        source.schedule(wallDeadline: .now() + seconds, repeating: .never, leeway: .seconds(1))
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.resume()
        self.source = source
    }

    public func cancel() {
        source?.cancel()
        source = nil
    }
}

/// Keeps one timer on the next moment the surfaces change at, and says so when it comes.
///
/// It computes the moments from `inputs` (see `DayClockInput.moments(after:)`), arms the timer for the earliest
/// and fires one event per moment. It starts again from the new present whenever the Mac wakes or its time zone,
/// clock or calendar day changes, and whenever `recompute()` is called because the day was read again. The 04:00
/// boundary is the one moment that reschedules everything else, so a Mac that slept through it reports it on wake.
@MainActor
public final class DayClock {
    /// What made the clock look again.
    public enum Cause: Sendable, Equatable {
        case wake, timeZone, clock, calendarDay
    }

    public enum Event: Sendable, Equatable {
        /// A scheduled moment came.
        case moment(DayMoment)
        /// The Mac woke or its time or zone changed. What was scheduled has been worked out again and what the
        /// surfaces show may be stale; moments that came and went in the meantime are not replayed.
        case changed(Cause)
    }

    private let clock: any Clock
    private let timer: any DayClockTimer
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let inputs: @MainActor () -> DayClockInput
    private let onEvent: @MainActor (Event) -> Void
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var upcoming: [DayMoment] = []
    private var lastDay: LocalDate?
    private var started = false

    public init(
        clock: any Clock, timer: any DayClockTimer = WallClockTimer(), center: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        inputs: @escaping @MainActor () -> DayClockInput, onEvent: @escaping @MainActor (Event) -> Void
    ) {
        self.clock = clock
        self.timer = timer
        self.center = center
        self.workspaceCenter = workspaceCenter
        self.inputs = inputs
        self.onEvent = onEvent
    }

    /// Starts listening and arms the timer. Says nothing: the first read of the day is the caller's.
    public func start() {
        guard !started else { return }
        started = true
        observe(workspaceCenter, NSWorkspace.didWakeNotification, .wake)
        observe(center, .NSSystemTimeZoneDidChange, .timeZone)
        observe(center, .NSSystemClockDidChange, .clock)
        observe(center, .NSCalendarDayChanged, .calendarDay)
        update(cause: nil)
    }

    public func stop() {
        guard started else { return }
        started = false
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
        upcoming = []
        lastDay = nil
        timer.cancel()
    }

    /// The input changed, for instance because the day was read again: work out the moments again. A moment
    /// that has already come is fired first, so reading the day just after the boundary cannot lose it.
    public func recompute() {
        guard started else { return }
        update(cause: nil)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ cause: Cause) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(cause: cause) }
        }
        observers.append((center, token))
    }

    private func update(cause: Cause?) {
        let now = clock.now()
        let input = inputs()
        let day = input.day(at: now)
        var events: [Event] = []
        if let cause {
            events.append(.changed(cause))
            // A Mac that slept through the boundary, or a zone that moved the day, has a new workday to report.
            if let lastDay, lastDay != day {
                events.append(.moment(DayMoment(at: input.rules.boundary.interval(of: day, in: input.zone).start, kind: .boundary)))
            }
        } else {
            events = upcoming.filter { $0.at <= now }.map { .moment($0) }
        }
        lastDay = day
        upcoming = input.moments(after: now)
        if let next = upcoming.first {
            timer.arm(at: next.at, now: now) { [weak self] in self?.recompute() }
        } else {
            timer.cancel()
        }
        // State is settled before anyone hears, so a callback may call `recompute()`.
        for event in events { onEvent(event) }
    }
}

extension DayClock {
    /// Recomputes each time the model publishes a read, which is when a first activity, a seal or a new previous
    /// day becomes known. Observation fires once per change, so it arms itself again.
    public func follow(_ model: DayModel) {
        withObservationTracking {
            _ = model.load
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.recompute()
                self?.follow(model)
            }
        }
    }
}
