import Foundation
import Testing

@testable import CadenceCore

/// The decision logic of the store observer, driven by a scripted store and a hand-moved clock
/// (docs/SPEC.md sections 8.2, 8.6 and 8.7).
@Suite struct StoreChangeDetectorTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A detector over a store whose reading moves only when the test moves it. Every read is counted.
    final class Harness {
        var detector: StoreChangeDetector
        var reading: StoreReading = .version(1)
        private(set) var reads = 0

        init(visible: Bool = false) {
            detector = StoreChangeDetector(timing: .standard, visible: visible, now: StoreChangeDetectorTests.t0)
        }

        /// A harness that has already made its first check, so a test starts from a settled state.
        static func settled(visible: Bool = false) -> Harness {
            let harness = Harness(visible: visible)
            let initial = harness.wake(at: StoreChangeDetectorTests.t0)
            #expect(initial)
            return harness
        }

        func read() -> StoreReading {
            reads += 1
            return reading
        }

        /// One wake: true when the detector asks for a reload.
        @discardableResult
        func wake(at now: Date) -> Bool {
            detector.wake(at: now, read: read)
        }

        func wakeWhenDue() -> Bool { wake(at: detector.nextWake) }

        func signal(at now: Date) { detector.signal(at: now) }

        func setVisible(_ visible: Bool, at now: Date) { detector.setVisible(visible, at: now) }

        func commit() {
            if case .version(let v) = reading { reading = .version(v + 1) }
        }

        var nextWake: Date { detector.nextWake }
    }

    static func after(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func theFirstCheckHappensAtOnceAndAsksForTheInitialLoad() {
        let harness = Harness()
        #expect(harness.nextWake == Self.t0)
        #expect(harness.wake(at: Self.t0))
        #expect(harness.reads == 1)
    }

    @Test func aWakeBeforeTheDeadlineReadsNothing() {
        let harness = Harness.settled()
        let reads = harness.reads
        #expect(harness.wake(at: Self.after(1)) == false)
        #expect(harness.reads == reads)
    }

    // MARK: coalescing

    @Test func aBurstOfOneHundredWritesIsOneCheckAndOneReload() {
        let harness = Harness.settled()
        let reads = harness.reads
        let start = Self.after(10)
        for i in 0..<100 {
            harness.commit()
            harness.signal(at: start.addingTimeInterval(Double(i) * 0.001))
        }
        // The window opens at the first signal; later signals neither extend it nor add a check.
        #expect(harness.nextWake == start.addingTimeInterval(StoreWatchTiming.standard.coalesce))
        #expect(harness.wakeWhenDue())
        #expect(harness.reads == reads + 1)
        // Nothing is left pending: the next wake is the poll, not another check.
        #expect(harness.nextWake > start.addingTimeInterval(StoreWatchTiming.standard.coalesce + 1))
    }

    @Test func aBurstThatChangedNothingReloadsNothing() {
        let harness = Harness.settled()
        let start = Self.after(10)
        for i in 0..<100 { harness.signal(at: start.addingTimeInterval(Double(i) * 0.001)) }
        #expect(harness.wakeWhenDue() == false)
        #expect(harness.reads == 2)
    }

    @Test func steadyWritesReloadAtMostOncePerWindow() {
        let harness = Harness.settled()
        var reloads: [Date] = []
        // A write every 10 ms for 10 s, with the driver waking whenever the detector asks.
        var now = Self.t0
        for _ in 0..<1000 {
            now = now.addingTimeInterval(0.01)
            harness.commit()
            harness.signal(at: now)
            if now >= harness.nextWake, harness.wake(at: now) { reloads.append(now) }
        }
        #expect(reloads.count >= 40)
        #expect(reloads.count <= 50)
        for (earlier, later) in zip(reloads, reloads.dropFirst()) {
            #expect(later.timeIntervalSince(earlier) >= StoreWatchTiming.standard.coalesce - 1e-9)
        }
    }

    @Test func aSignalAfterTheCheckOpensANewWindow() {
        let harness = Harness.settled()
        harness.signal(at: Self.after(10))
        harness.commit()
        #expect(harness.wakeWhenDue())
        let later = Self.after(20)
        harness.signal(at: later)
        harness.commit()
        #expect(harness.nextWake == later.addingTimeInterval(StoreWatchTiming.standard.coalesce))
        #expect(harness.wakeWhenDue())
    }

    // MARK: the polling fallback

    @Test func hiddenPollsComeEveryThirtySeconds() {
        let harness = Harness.settled(visible: false)
        #expect(harness.nextWake == Self.after(30))
        #expect(harness.wake(at: Self.after(29.9)) == false)
        #expect(harness.reads == 1)
        #expect(harness.wake(at: Self.after(30)) == false)
        #expect(harness.reads == 2)
        #expect(harness.nextWake == Self.after(60))
    }

    @Test func visiblePollsComeEveryTwoSeconds() {
        let harness = Harness.settled(visible: true)
        var now = Self.t0
        for _ in 0..<5 {
            #expect(harness.nextWake == now.addingTimeInterval(2))
            now = harness.nextWake
            #expect(harness.wake(at: now) == false)
        }
        #expect(harness.reads == 6)
    }

    @Test func aMissedNotificationIsCaughtByTheNextPoll() {
        let harness = Harness.settled(visible: true)
        harness.commit()  // no signal arrives
        #expect(harness.wake(at: Self.after(2)))
        #expect(harness.wake(at: Self.after(4)) == false)
    }

    @Test func showingTheViewChecksAtOnceAndThenPollsEveryTwoSeconds() {
        let harness = Harness.settled(visible: false)
        let shown = Self.after(5)
        harness.commit()
        harness.setVisible(true, at: shown)
        #expect(harness.nextWake == shown)
        #expect(harness.wake(at: shown))
        #expect(harness.nextWake == shown.addingTimeInterval(2))
    }

    @Test func hidingTheViewBacksOffToThirtySeconds() {
        let harness = Harness.settled(visible: true)
        #expect(harness.wake(at: Self.after(2)) == false)
        harness.setVisible(false, at: Self.after(3))
        #expect(harness.nextWake == Self.after(32))
    }

    @Test func hidingKeepsAPendingCheck() {
        let harness = Harness.settled(visible: true)
        let signalled = Self.after(1)
        harness.signal(at: signalled)
        harness.commit()
        harness.setVisible(false, at: signalled.addingTimeInterval(0.05))
        #expect(harness.nextWake == signalled.addingTimeInterval(StoreWatchTiming.standard.coalesce))
    }

    @Test func changingVisibilityBeforeTheFirstCheckDoesNotDelayIt() {
        let harness = Harness(visible: false)
        harness.setVisible(true, at: Self.t0)
        harness.setVisible(false, at: Self.t0)
        #expect(harness.nextWake == Self.t0)
        #expect(harness.wake(at: Self.t0))
        #expect(harness.nextWake == Self.after(30))
    }

    @Test func settingTheSameVisibilityChangesNothing() {
        let harness = Harness.settled(visible: true)
        let before = harness.nextWake
        harness.setVisible(true, at: Self.after(1))
        #expect(harness.nextWake == before)
    }

    // MARK: an unreadable store

    @Test func anUnreadableStoreAsksForOneReloadSoTheErrorShows() {
        let harness = Harness(visible: true)
        harness.reading = .unreadable
        #expect(harness.wake(at: Self.t0))
        // Still unreadable on the next polls: nothing new to show.
        #expect(harness.wake(at: Self.after(2)) == false)
        #expect(harness.wake(at: Self.after(4)) == false)
        // It becomes readable, and later unreadable again: both are changes.
        harness.reading = .version(7)
        #expect(harness.wake(at: Self.after(6)))
        harness.reading = .unreadable
        #expect(harness.wake(at: Self.after(8)))
    }
}
