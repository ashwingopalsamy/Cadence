import Foundation

/// Where presence events come from. The macOS app implements it in its presence adapter (section 8.5); tests
/// and replays feed `PresenceEngine.handle` directly.
///
/// The adapter delivers every event serially, on one queue, to the closure given to `start`. Mapping:
///
/// - Every 30 s while a span is open and every 60 s otherwise: `.sample(idleSeconds:unlocked:)`, with
///   `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)`
///   (any input, no Accessibility permission; `.null` does not mean any input, see `docs/SPIKES.md` S4) and `unlocked` true when `CGSessionCopyCurrentDictionary()` has
///   `kCGSessionOnConsoleKey` true and no `CGSSessionScreenIsLocked`.
/// - `NSWorkspace.willSleepNotification`: `.sleep`. `NSWorkspace.didWakeNotification`: `.wake`.
/// - `com.apple.screenIsLocked` on `DistributedNotificationCenter`: `.lock`. `com.apple.screenIsUnlocked`: `.unlock`.
/// - `NSWorkspace.sessionDidResignActiveNotification`: `.sessionResigned`.
///   `NSWorkspace.sessionDidBecomeActiveNotification`: `.sessionActive`.
/// - `NSWorkspace.willPowerOffNotification`: `.powerOff`.
/// - `applicationWillTerminate`: `.stop`.
///
/// Screen sleep, screensavers and app launches and quits are not presence and are not delivered: section 8.4
/// closes spans on sleep, lock, logout and power off only. Only idle seconds are read, never keys, apps or
/// window titles (section 15).
public protocol PresenceEventSource: AnyObject {
    func start(_ deliver: @escaping (PresenceEvent) -> Void)
    func stop()
}

/// What one event wrote.
public struct PresenceWrite: Sendable, Equatable {
    /// `presence.span` events appended, one per workday piece.
    public var spans: Int
    /// `day.started` events appended.
    public var dayStarts: Int

    public static let none = PresenceWrite(spans: 0, dayStarts: 0)
}

/// The presence engine: the pure `PresenceMachine` with the Journal behind it and a clock in front.
///
/// Each event is read at `clock.now()`, run through the machine and written in one transaction. A write that
/// fails leaves the machine as it was, so the event can be handed over again. `machine` is small and `Codable`:
/// the app saves it after each event and passes it back after a restart, so a span left open by a crash is
/// closed at its last input instead of being lost.
public final class PresenceEngine {
    public private(set) var machine: PresenceMachine
    let journal: Journal
    let clock: any Clock

    public init(journal: Journal, clock: any Clock, rules: PresenceRules = .standard, restoring saved: PresenceMachine? = nil) {
        self.journal = journal
        self.clock = clock
        self.machine = saved ?? PresenceMachine(rules: rules)
    }

    /// `at` is the instant the event happened, captured by the adapter on first delivery. A retry passes the same
    /// instant, so a write that failed does not move the event to the time of the retry.
    @discardableResult
    public func handle(_ event: PresenceEvent, at instant: Date? = nil) throws(CadenceError) -> PresenceWrite {
        var next = machine
        let outputs = next.handle(event, at: instant ?? clock.now(), calendar: JournalPresenceCalendar(journal: journal))
        let written = try journal.recordPresence(outputs)
        machine = next
        return written
    }
}

/// Workdays as the Journal places them: each day in the zone it was recorded in, a new day in the profile zone,
/// as collected presence is placed.
struct JournalPresenceCalendar: PresenceCalendar {
    let journal: Journal

    func workday(of instant: Date) -> PresenceDay {
        let boundary = journal.config.dayBoundary
        let (day, zone) = (try? journal.workday(of: instant)) ?? (boundary.day(of: instant, in: journal.zone), journal.zone)
        return PresenceDay(day: day, zone: zone, start: boundary.interval(of: day, in: zone).start)
    }
}

extension Journal {
    /// Writes what the presence machine asked for, as the app, in one transaction (sections 3, 7.3, 8.4).
    ///
    /// Spans carry their source (`input`, `wake` or `unlock`) and follow the gap rule collected presence uses:
    /// cut at each day boundary in the day's own zone, whole seconds, only what no span of that day already
    /// covers. Observed presence has no minimum length, because the end of the last span is the day's last activity. So a replay, or a span a backfill or collector already wrote, writes
    /// nothing twice. A span is never written past the clock (after the clock was set back) or on a day after
    /// today. `day.started` is written, source `input`, only when that day has no `day.started` or first activity yet, so a manual
    /// correction stands and a restart does not start the day again.
    public func recordPresence(_ outputs: [PresenceOutput], actor: Actor = .app) throws(CadenceError) -> PresenceWrite {
        guard !outputs.isEmpty else { return .none }
        let now = clock.now()
        // The workday of now, placed as the spans are: after a move west the profile's date can still be yesterday
        // while the day's own zone has reached the next one, and that span is not in the future.
        let today = try workday(of: now).0
        return try store.transact { () throws(CadenceError) -> PresenceWrite in
            var written = PresenceWrite.none
            for output in outputs {
                switch output {
                case .span(let start, let end, let source):
                    let end = min(end, now)
                    guard end > start, let pieces = try self.uncoveredPresence(from: start, to: end, minimum: 1) else { continue }
                    for piece in pieces where piece.day <= today {
                        let payload = PresenceSpanPayload(
                            day: piece.day.description, tz: piece.zone.identifier,
                            start: Timestamp.local(piece.start, in: piece.zone),
                            end: Timestamp.local(piece.end, in: piece.zone), source: source)
                        guard (try? PresenceSpanPayload(json: payload.json)) != nil else { continue }
                        try self.append([EventPayload.presenceSpan(payload).draft(actor: actor)])
                        written.spans += 1
                    }
                case .dayStarted(let day, let zone, let at):
                    guard day <= today, at <= now else { continue }
                    let started = try self.rows(
                        "SELECT 1 AS found FROM events WHERE subject = ? AND type = 'day.started' LIMIT 1",
                        [.text("day:\(day)")])
                    guard started.isEmpty else { continue }
                    let known = try self.rows("SELECT first_activity FROM days WHERE date = ?", [.text(day.description)])
                    guard known.first?.text("first_activity") == nil else { continue }
                    let mark = DayMark(day: day.description, tz: zone.identifier, at: Timestamp.local(at, in: zone), source: .input)
                    guard (try? DayMark(json: mark.json)) != nil else { continue }
                    try self.append([EventPayload.dayStarted(mark).draft(actor: actor)])
                    written.dayStarts += 1
                }
            }
            return written
        }
    }
}
