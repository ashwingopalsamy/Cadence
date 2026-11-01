import Foundation
import Testing

@testable import CadenceCore

/// The pure state machine of docs/SPEC.md section 8.4, fed synthetic streams.
@Suite struct PresenceMachineTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    let calendar = FixedPresenceCalendar(zone: Self.zone, boundary: .standard)

    /// An instant on a calendar date in Kolkata.
    static func at(_ date: String, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Timestamp.resolve(LocalDate(date)!, hour: hour, minute: minute, in: zone).addingTimeInterval(Double(second))
    }

    static func day(_ text: String) -> LocalDate { LocalDate(text)! }

    /// Feeds events and collects every output.
    struct Run {
        var machine = PresenceMachine()
        var outputs: [PresenceOutput] = []
        let calendar: FixedPresenceCalendar

        mutating func send(_ event: PresenceEvent, at t: Date) {
            outputs += machine.handle(event, at: t, calendar: calendar)
        }

        /// A sample every `step` seconds from `from` to `to` inclusive, with input `idle` seconds before each.
        mutating func active(from: Date, to: Date, step: TimeInterval = 30, idle: Double = 0) {
            var t = from
            while t <= to {
                send(.sample(idleSeconds: idle, unlocked: true), at: t)
                t = t.addingTimeInterval(step)
            }
        }

        /// Samples while the session reports itself locked: input there is the lock screen, not work.
        mutating func locked(from: Date, to: Date, step: TimeInterval = 30) {
            var t = from
            while t <= to {
                send(.sample(idleSeconds: 0, unlocked: false), at: t)
                t = t.addingTimeInterval(step)
            }
        }

        var spans: [PresenceOutput] { outputs.filter { if case .span = $0 { true } else { false } } }
        var starts: [PresenceOutput] { outputs.filter { if case .dayStarted = $0 { true } else { false } } }
    }

    func run() -> Run { Run(calendar: calendar) }

    func span(_ a: Date, _ b: Date, _ source: PresenceSource = .input) -> PresenceOutput {
        .span(start: a, end: b, source: source)
    }

    func started(_ day: String, _ at: Date) -> PresenceOutput {
        .dayStarted(day: Self.day(day), zone: Self.zone, at: at)
    }

    // MARK: - Idle

    @Test func opensAtInputAndClosesAtTheLastActivityAfterFiveMinutes() {
        var r = run()
        r.send(.sample(idleSeconds: 2, unlocked: true), at: Self.at("2026-10-29", 9, 0, 2))
        #expect(r.outputs == [started("2026-10-29", Self.at("2026-10-29", 9, 0))])
        r.active(from: Self.at("2026-10-29", 9, 0, 30), to: Self.at("2026-10-29", 10, 0))
        // Idle from 10:00:00: samples see the idle time grow.
        r.send(.sample(idleSeconds: 120, unlocked: true), at: Self.at("2026-10-29", 10, 2))
        r.send(.sample(idleSeconds: 240, unlocked: true), at: Self.at("2026-10-29", 10, 4))
        #expect(r.spans.isEmpty)
        r.send(.sample(idleSeconds: 360, unlocked: true), at: Self.at("2026-10-29", 10, 6))
        #expect(r.spans == [span(Self.at("2026-10-29", 9, 0), Self.at("2026-10-29", 10, 0))])
        #expect(r.machine.isOpen == false)
    }

    @Test func fourMinutesFiftyNineIdleKeepsTheSpanAndFiveMinutesClosesIt() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 9, 30))
        r.send(.sample(idleSeconds: 299, unlocked: true), at: Self.at("2026-10-29", 9, 34, 59))
        #expect(r.spans.isEmpty)
        #expect(r.machine.isOpen)
        // Input again: the same span carries on.
        r.active(from: Self.at("2026-10-29", 9, 35), to: Self.at("2026-10-29", 9, 40))
        r.send(.sample(idleSeconds: 300, unlocked: true), at: Self.at("2026-10-29", 9, 45))
        #expect(r.spans == [span(Self.at("2026-10-29", 9, 0), Self.at("2026-10-29", 9, 40))])
    }

    @Test func idleInputDoesNotOpenASpan() {
        var r = run()
        r.send(.sample(idleSeconds: 5, unlocked: true), at: Self.at("2026-10-29", 9, 0))
        r.send(.sample(idleSeconds: 40, unlocked: true), at: Self.at("2026-10-29", 9, 1))
        #expect(r.outputs.isEmpty)
        #expect(r.machine.isOpen == false)
    }

    @Test func badSamplesAreIgnored() {
        var r = run()
        r.send(.sample(idleSeconds: -1, unlocked: true), at: Self.at("2026-10-29", 9, 0))
        r.send(.sample(idleSeconds: .nan, unlocked: true), at: Self.at("2026-10-29", 9, 0, 30))
        r.send(.sample(idleSeconds: .infinity, unlocked: true), at: Self.at("2026-10-29", 9, 1))
        #expect(r.outputs.isEmpty)
    }

    // MARK: - The day boundary

    @Test func aSpanAcrossTheBoundaryIsCutAt0400AndTheNewDayStarts() {
        var r = run()
        r.active(from: Self.at("2026-10-30", 3, 0), to: Self.at("2026-10-30", 5, 0))
        r.send(.sample(idleSeconds: 300, unlocked: true), at: Self.at("2026-10-30", 5, 5))
        #expect(
            r.spans == [
                span(Self.at("2026-10-30", 3, 0), Self.at("2026-10-30", 4, 0)),
                span(Self.at("2026-10-30", 4, 0), Self.at("2026-10-30", 5, 0)),
            ])
        #expect(
            r.starts == [started("2026-10-29", Self.at("2026-10-30", 3, 0)), started("2026-10-30", Self.at("2026-10-30", 4, 0))])
    }

    @Test func aSpanAcrossMidnightStaysOnOneDay() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 23, 0), to: Self.at("2026-10-30", 1, 0))
        r.send(.sample(idleSeconds: 300, unlocked: true), at: Self.at("2026-10-30", 1, 5))
        #expect(r.spans == [span(Self.at("2026-10-29", 23, 0), Self.at("2026-10-30", 1, 0))])
        #expect(r.starts == [started("2026-10-29", Self.at("2026-10-29", 23, 0))])
    }

    @Test func aSpanAcrossMidnightAndTheBoundaryIsCutOnlyAtTheBoundary() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 22, 0), to: Self.at("2026-10-30", 4, 30), step: 60)
        r.send(.sample(idleSeconds: 300, unlocked: true), at: Self.at("2026-10-30", 4, 35))
        #expect(
            r.spans == [
                span(Self.at("2026-10-29", 22, 0), Self.at("2026-10-30", 4, 0)),
                span(Self.at("2026-10-30", 4, 0), Self.at("2026-10-30", 4, 30)),
            ])
        #expect(r.starts.count == 2)
    }

    @Test func anOvernightAwakeMacWithNoInputDoesNotStartADay() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 19, 0), to: Self.at("2026-10-29", 20, 0))
        var t = Self.at("2026-10-29", 20, 1)
        while t <= Self.at("2026-10-30", 9, 0) {
            r.send(.sample(idleSeconds: t.timeIntervalSince(Self.at("2026-10-29", 20, 0)), unlocked: true), at: t)
            t = t.addingTimeInterval(60)
        }
        #expect(r.spans == [span(Self.at("2026-10-29", 19, 0), Self.at("2026-10-29", 20, 0))])
        #expect(r.starts == [started("2026-10-29", Self.at("2026-10-29", 19, 0))])
    }

    // MARK: - Sleep, lock, session

    @Test func sleepClosesAtTheEventAndWakeReopensOnTheNextInput() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 9, 30))
        r.send(.sleep, at: Self.at("2026-10-29", 9, 32))
        #expect(r.spans == [span(Self.at("2026-10-29", 9, 0), Self.at("2026-10-29", 9, 32))])
        r.send(.wake, at: Self.at("2026-10-29", 10, 0))
        r.send(.sample(idleSeconds: 20, unlocked: true), at: Self.at("2026-10-29", 10, 0, 30))
        #expect(r.machine.isOpen == false)
        r.send(.sample(idleSeconds: 1, unlocked: true), at: Self.at("2026-10-29", 10, 1))
        #expect(r.machine.isOpen)
        r.send(.sleep, at: Self.at("2026-10-29", 10, 3))
        #expect(r.spans.last == span(Self.at("2026-10-29", 10, 0, 59), Self.at("2026-10-29", 10, 3), .wake))
        #expect(r.starts.count == 1)
    }

    @Test func sleepAfterFiveMinutesWithoutInputClosesAtTheLastInput() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 9, 30))
        r.send(.sample(idleSeconds: 60, unlocked: true), at: Self.at("2026-10-29", 9, 31))
        r.send(.sample(idleSeconds: 240, unlocked: true), at: Self.at("2026-10-29", 9, 34))
        r.send(.sleep, at: Self.at("2026-10-29", 9, 35, 30))
        #expect(r.spans == [span(Self.at("2026-10-29", 9, 0), Self.at("2026-10-29", 9, 30))])
    }

    @Test func aSampleAfterAMissedWakeCountsAsAWake() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 9, 10))
        r.send(.sleep, at: Self.at("2026-10-29", 9, 11))
        r.active(from: Self.at("2026-10-29", 9, 30), to: Self.at("2026-10-29", 9, 39))
        r.send(.powerOff, at: Self.at("2026-10-29", 9, 40))
        #expect(r.spans.last == span(Self.at("2026-10-29", 9, 30), Self.at("2026-10-29", 9, 40), .wake))
    }

    @Test func lockAt1300AndUnlockAt1400() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 12, 0), to: Self.at("2026-10-29", 12, 59, 30))
        r.send(.lock, at: Self.at("2026-10-29", 13, 0))
        #expect(r.spans == [span(Self.at("2026-10-29", 12, 0), Self.at("2026-10-29", 13, 0))])
        // Typing a password on the lock screen is input, but the session is locked.
        r.locked(from: Self.at("2026-10-29", 13, 59), to: Self.at("2026-10-29", 13, 59, 30))
        #expect(r.machine.isOpen == false)
        r.send(.unlock, at: Self.at("2026-10-29", 14, 0))
        r.active(from: Self.at("2026-10-29", 14, 0, 10), to: Self.at("2026-10-29", 15, 0))
        r.send(.lock, at: Self.at("2026-10-29", 15, 1))
        #expect(r.spans.last == span(Self.at("2026-10-29", 14, 0, 10), Self.at("2026-10-29", 15, 1), .unlock))
        #expect(r.starts.count == 1)
    }

    @Test func samplesCarryTheLockStateWhenANotificationIsMissed() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 12, 0), to: Self.at("2026-10-29", 12, 30))
        r.send(.sample(idleSeconds: 0, unlocked: false), at: Self.at("2026-10-29", 12, 31))
        #expect(r.spans == [span(Self.at("2026-10-29", 12, 0), Self.at("2026-10-29", 12, 31))])
        r.send(.sample(idleSeconds: 0, unlocked: false), at: Self.at("2026-10-29", 12, 32))
        #expect(r.spans.count == 1)
        r.send(.sample(idleSeconds: 0, unlocked: true), at: Self.at("2026-10-29", 12, 33))
        r.send(.stop, at: Self.at("2026-10-29", 12, 36))
        #expect(r.spans.last == span(Self.at("2026-10-29", 12, 33), Self.at("2026-10-29", 12, 36), .unlock))
    }

    @Test func fastUserSwitchingActsAsLockAndUnlock() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 12, 0), to: Self.at("2026-10-29", 12, 30))
        r.send(.sessionResigned, at: Self.at("2026-10-29", 12, 31))
        r.locked(from: Self.at("2026-10-29", 12, 32), to: Self.at("2026-10-29", 12, 40))
        r.send(.sessionActive, at: Self.at("2026-10-29", 12, 45))
        r.send(.sample(idleSeconds: 0, unlocked: true), at: Self.at("2026-10-29", 12, 45, 30))
        r.send(.lock, at: Self.at("2026-10-29", 12, 50))
        #expect(
            r.spans == [
                span(Self.at("2026-10-29", 12, 0), Self.at("2026-10-29", 12, 31)),
                span(Self.at("2026-10-29", 12, 45, 30), Self.at("2026-10-29", 12, 50), .unlock),
            ])
    }

    // MARK: - Clock jumps

    @Test func aBackwardJumpClosesTheSpanAtTheLastInputAndStartsAgain() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        r.send(.sample(idleSeconds: 0, unlocked: true), at: Self.at("2026-10-29", 9, 30))
        #expect(r.spans == [span(Self.at("2026-10-29", 9, 0), Self.at("2026-10-29", 10, 0))])
        r.active(from: Self.at("2026-10-29", 9, 30, 30), to: Self.at("2026-10-29", 9, 45))
        r.send(.stop, at: Self.at("2026-10-29", 9, 46))
        #expect(r.spans.last == span(Self.at("2026-10-29", 9, 30), Self.at("2026-10-29", 9, 46)))
    }

    @Test func aForwardJumpClosesTheSpanAtTheLastInputBeforeIt() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        r.send(.sample(idleSeconds: 0, unlocked: true), at: Self.at("2026-10-29", 12, 0))
        #expect(r.spans == [span(Self.at("2026-10-29", 9, 0), Self.at("2026-10-29", 10, 0))])
        #expect(r.machine.isOpen)
        r.send(.stop, at: Self.at("2026-10-29", 12, 3))
        #expect(r.spans.last == span(Self.at("2026-10-29", 12, 0), Self.at("2026-10-29", 12, 3)))
    }

    @Test func aGapUnderFiveMinutesIsNotAJump() {
        var r = run()
        r.active(from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        r.send(.sample(idleSeconds: 0, unlocked: true), at: Self.at("2026-10-29", 10, 4, 59))
        r.send(.stop, at: Self.at("2026-10-29", 10, 5, 30))
        #expect(r.spans == [span(Self.at("2026-10-29", 9, 0), Self.at("2026-10-29", 10, 5, 30))])
    }

    // MARK: - Restart

    @Test func aRestoredSnapshotClosesAStaleSpanAtItsLastInput() throws {
        var r = run()
        r.active(from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        let saved = try JSONEncoder().encode(r.machine)
        // The app crashed: no close event. The next launch restores the snapshot.
        var restored = Run(machine: try JSONDecoder().decode(PresenceMachine.self, from: saved), calendar: calendar)
        #expect(restored.machine == r.machine)
        restored.send(.sample(idleSeconds: 0, unlocked: true), at: Self.at("2026-10-29", 10, 40))
        #expect(restored.spans == [span(Self.at("2026-10-29", 9, 0), Self.at("2026-10-29", 10, 0))])
        #expect(restored.starts.isEmpty)
    }

    @Test func theSameStreamGivesTheSameOutputs() {
        func stream() -> [PresenceOutput] {
            var r = run()
            r.active(from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 9, 20))
            r.send(.lock, at: Self.at("2026-10-29", 9, 21))
            r.send(.unlock, at: Self.at("2026-10-29", 9, 40))
            r.active(from: Self.at("2026-10-30", 3, 50), to: Self.at("2026-10-30", 4, 10))
            r.send(.sleep, at: Self.at("2026-10-30", 4, 11))
            return r.outputs
        }
        #expect(stream() == stream())
        #expect(!stream().isEmpty)
    }
}
