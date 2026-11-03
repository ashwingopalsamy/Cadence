import Foundation
import Testing

@testable import CadenceCore

/// The observer against real SQLite files and real timers, with short intervals so the suite stays fast
/// (docs/SPEC.md sections 8.2 and 8.7). The notification is replaced by a signal the test fires, so the same
/// tests run on Linux, where only polling exists.
@Suite struct StoreObserverTests {
    struct WallClock: Clock {
        func now() -> Date { Date() }
    }

    /// The test's stand-in for the Darwin notification.
    final class ManualSignal: StoreChangeSignal, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable () -> Void)?

        func start(_ handler: @escaping @Sendable () -> Void) { lock.withLock { self.handler = handler } }
        func stop() { lock.withLock { handler = nil } }
        func fire() { lock.withLock { handler }?() }
    }

    /// Records each `onChange` with the time it arrived.
    final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Date] = []

        var count: Int { lock.withLock { times.count } }
        var last: Date? { lock.withLock { times.last } }

        func record() { lock.withLock { times.append(Date()) } }

        /// True once `count` reaches `target`, polling the count every 5 ms.
        func wait(for target: Int, timeout: TimeInterval = 3) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if count >= target { return true }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return count >= target
        }
    }

    /// Fast intervals: the coalescing window and both polls are tens of milliseconds.
    static let quick = StoreWatchTiming(visiblePoll: 0.05, hiddenPoll: 0.05, coalesce: 0.03)
    /// Polls so slow that only the notification can wake it in a test.
    static let notificationOnly = StoreWatchTiming(visiblePoll: 3600, hiddenPoll: 3600, coalesce: 0.03)

    struct Fixture {
        let path: String
        let store: SQLiteStore
        let signal = ManualSignal()
        let changes = Changes()

        init() throws {
            path = TestStore.tempDirectory("observer").appendingPathComponent("cadence.db").path
            store = try TestStore.make(path: path)
            try store.append([EventDraft(type: "ledger.genesis", subject: "ledger", data: ["created": "2026-09-21"], actor: .app)])
            // A real writer posts after its commit; here that post fires the manual signal.
            let signal = signal
            store.db.afterCommit = { signal.fire() }
        }

        func observer(timing: StoreWatchTiming, visible: Bool = false, path: String? = nil) -> StoreObserver {
            let changes = changes
            return StoreObserver(
                source: StoreVersionProbe(path: path ?? self.path), clock: WallClock(), timing: timing, visible: visible,
                signal: signal, onChange: { changes.record() })
        }

        @discardableResult
        func write(_ n: Int = 1) throws -> Date {
            for _ in 0..<n {
                try store.append([EventDraft(type: "note.added", subject: "day:2026-09-21", data: [:], actor: .app)])
            }
            return Date()
        }
    }

    // MARK: detection

    @Test func theFirstCheckIsTheInitialLoad() throws {
        let f = try Fixture()
        let observer = f.observer(timing: Self.notificationOnly)
        observer.start()
        defer { observer.stop() }
        #expect(f.changes.wait(for: 1))
    }

    @Test func aSecondConnectionsCommitIsDetectedThroughTheNotification() throws {
        let f = try Fixture()
        let observer = f.observer(timing: Self.notificationOnly)
        observer.start()
        defer { observer.stop() }
        #expect(f.changes.wait(for: 1))
        // The store's connection is not the probe's connection: the probe sees this commit as another writer's.
        let wrote = try f.write()
        #expect(f.changes.wait(for: 2, timeout: 1))
        let latency = try #require(f.changes.last).timeIntervalSince(wrote)
        #expect(latency < 0.5)
    }

    @Test func pollingAloneCatchesACommitWhenTheNotificationIsLost() throws {
        let f = try Fixture()
        f.store.db.afterCommit = nil  // the post never happens
        let observer = f.observer(timing: Self.quick, visible: true)
        observer.start()
        defer { observer.stop() }
        #expect(f.changes.wait(for: 1))
        try f.write()
        #expect(f.changes.wait(for: 2, timeout: 1))
    }

    @Test func aSpuriousNotificationReloadsNothing() throws {
        let f = try Fixture()
        let observer = f.observer(timing: Self.notificationOnly)
        observer.start()
        defer { observer.stop() }
        #expect(f.changes.wait(for: 1))
        for _ in 0..<20 { f.signal.fire() }  // somebody else's store, or a post for a rolled back write
        Thread.sleep(forTimeInterval: 0.3)
        #expect(f.changes.count == 1)
    }

    @Test func aBurstOfOneHundredWritesIsFarFewerThanOneHundredReloads() throws {
        let f = try Fixture()
        let observer = f.observer(timing: StoreWatchTiming(visiblePoll: 3600, hiddenPoll: 3600, coalesce: 0.2))
        observer.start()
        defer { observer.stop() }
        #expect(f.changes.wait(for: 1))
        let started = Date()
        let finished = try f.write(100)
        Thread.sleep(forTimeInterval: 0.6)
        let reloads = f.changes.count - 1
        // One window of 200 ms gathers every write that lands inside it.
        let windows = Int((finished.timeIntervalSince(started) / 0.2).rounded(.up)) + 1
        #expect(reloads >= 1)
        #expect(reloads <= windows)
        #expect(reloads < 50)
        // The last reload came after the last write, so the final state is the one shown.
        // (The signal fires just before `finished` is read, hence the small allowance.)
        #expect(try #require(f.changes.last) >= finished.addingTimeInterval(-0.01))
    }

    @Test func aMissingStoreReadsAsUnreadableOnceAndRecoversWhenItAppears() throws {
        let folder = TestStore.tempDirectory("missing")
        let path = folder.appendingPathComponent("cadence.db").path
        let f = try Fixture()
        let observer = f.observer(timing: Self.quick, visible: true, path: path)
        observer.start()
        defer { observer.stop() }
        #expect(f.changes.wait(for: 1))  // the error shows
        Thread.sleep(forTimeInterval: 0.3)
        #expect(f.changes.count == 1)  // and is not reported again and again
        let made = try TestStore.make(path: path)
        try made.append([EventDraft(type: "ledger.genesis", subject: "ledger", data: ["created": "2026-09-21"], actor: .app)])
        #expect(f.changes.wait(for: 2, timeout: 1))  // and clears when the store exists
    }

    // MARK: stopping and visibility

    @Test func stopIsFinal() throws {
        let f = try Fixture()
        let observer = f.observer(timing: Self.quick, visible: true)
        observer.start()
        #expect(f.changes.wait(for: 1))
        observer.stop()
        observer.stop()  // twice is fine
        let seen = f.changes.count
        try f.write(3)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(f.changes.count == seen)
    }

    @Test func aStoppedObserverCanBeDroppedWithoutAFurtherCallback() throws {
        let f = try Fixture()
        var observer: StoreObserver? = f.observer(timing: Self.quick, visible: true)
        observer?.start()
        #expect(f.changes.wait(for: 1))
        observer = nil  // dropped without stop(): the timer and the signal go with it
        let seen = f.changes.count
        try f.write(3)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(f.changes.count == seen)
    }

    @Test func showingTheViewChecksAtOnce() throws {
        let f = try Fixture()
        f.store.db.afterCommit = nil
        let observer = f.observer(timing: Self.notificationOnly)
        observer.start()
        defer { observer.stop() }
        #expect(f.changes.wait(for: 1))
        try f.write()  // no notification, and the poll is an hour away
        Thread.sleep(forTimeInterval: 0.2)
        #expect(f.changes.count == 1)
        observer.setVisible(true)
        #expect(f.changes.wait(for: 2, timeout: 1))
    }

    // MARK: the probe

    @Test func theProbeReadsTheChangeCounterOfAnotherConnection() throws {
        let f = try Fixture()
        let probe = StoreVersionProbe(path: f.path)
        let before = probe.read()
        guard case .version = before else { Issue.record("expected a version, got \(before)"); return }
        #expect(probe.read() == before)  // idle: nothing moves
        try f.write()
        #expect(probe.read() != before)
    }

    @Test func theProbeReadsAMissingFileAsUnreadableAndTheFileOnceItExists() throws {
        let path = TestStore.tempDirectory("probe").appendingPathComponent("cadence.db").path
        let probe = StoreVersionProbe(path: path)
        #expect(probe.read() == .unreadable)
        _ = try TestStore.make(path: path)
        guard case .version = probe.read() else { Issue.record("expected a version"); return }
        try FileManager.default.removeItem(atPath: path)
        #expect(probe.read() == .unreadable)
    }

    #if canImport(Darwin)
    /// Needs the main run loop to be serviced, as it is in the app; see StoreObserverCLITests for the measured run.
    @Test func theDarwinSignalReachesAHandlerAfterAPost() async throws {
        let received = Changes()
        let signal = DarwinStoreChangeSignal()
        signal.start { received.record() }
        defer { signal.stop() }
        DarwinStoreChangePoster().postStoreChanged()
        let heard = await Task.detached { received.wait(for: 1, timeout: 2) }.value
        #expect(heard)
    }
    #endif
}
