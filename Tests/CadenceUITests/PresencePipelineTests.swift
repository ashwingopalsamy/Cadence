import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The presence adapter's pure parts (docs/SPEC.md section 8.4): events take their own time as they arrive, go to the
/// writer in order, keep that time on a retry, stop while capture is paused, and the machine behind them is saved
/// after each event so a crash closes the open span at its last input.
@Suite struct PresencePipelineTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!

    static func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        let text = String(format: "2026-10-29T%02d:%02d:%02d+05:30", hour, minute, second)
        return Timestamp.parse(text)!
    }

    /// An event source the test drives by hand.
    final class FakeSource: PresenceEventSource, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((PresenceEvent) -> Void)?
        private var stops = 0
        var stopCount: Int { lock.withLock { stops } }
        var started: Bool { lock.withLock { handler != nil } }

        func start(_ deliver: @escaping (PresenceEvent) -> Void) { lock.withLock { handler = deliver } }
        func stop() { lock.withLock { stops += 1; handler = nil } }
        func emit(_ event: PresenceEvent) { lock.withLock { handler }?(event) }
    }

    /// A recorder that remembers each call and fails as scripted.
    final class ScriptedRecorder: PresenceRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(event: PresenceEvent, instant: Date)] = []
        private var failures: [StoreFailure.Kind]
        init(failing: [StoreFailure.Kind] = []) { failures = failing }

        var calls: [(event: PresenceEvent, instant: Date)] { lock.withLock { log } }

        func recordPresence(_ event: PresenceEvent, at instant: Date) async -> Result<PresenceWrite, StoreFailure> {
            lock.withLock {
                log.append((event, instant))
                if let kind = failures.first {
                    failures.removeFirst()
                    return .failure(StoreFailure(kind: kind, detail: "scripted"))
                }
                return .success(.none)
            }
        }
    }

    struct SilentPoster: StoreChangePoster {
        func postStoreChanged() {}
    }

    func pipeline(
        _ recorder: any PresenceRecording, clock: ManualClock, retry: PresenceRetry = .standard
    ) -> PresencePipeline {
        // The retry delay moves the clock, so a retry that read the clock again would show.
        PresencePipeline(recorder: recorder, clock: clock, retry: retry, sleep: { seconds in clock.advance(by: seconds) })
    }

    // MARK: Order and time

    @Test func eventsReachTheRecorderInOrderEachAtItsOwnTime() async {
        let clock = ManualClock(Self.at(9, 0))
        let recorder = ScriptedRecorder()
        let source = FakeSource()
        let feed = pipeline(recorder, clock: clock)
        feed.start(source: source)

        let script: [(PresenceEvent, Date)] = [
            (.sample(idleSeconds: 0, unlocked: true), Self.at(9, 0)),
            (.sleep, Self.at(9, 10)),
            (.wake, Self.at(11, 0)),
            (.sample(idleSeconds: 1, unlocked: true), Self.at(11, 0, 5)),
            (.lock, Self.at(12, 0)),
            (.unlock, Self.at(13, 0)),
        ]
        for (event, time) in script {
            clock.set(time)
            source.emit(event)
        }
        await feed.drain()

        #expect(recorder.calls.map(\.event) == script.map(\.0))
        #expect(recorder.calls.map(\.instant) == script.map(\.1))
    }

    @Test func aRetryKeepsTheTimeTheEventHappenedAt() async {
        let clock = ManualClock(Self.at(9, 0))
        let recorder = ScriptedRecorder(failing: [.busy, .other])
        let source = FakeSource()
        let feed = pipeline(recorder, clock: clock)
        feed.start(source: source)

        clock.set(Self.at(9, 30))
        source.emit(.lock)
        await feed.drain()

        let calls = recorder.calls
        #expect(calls.count == 3)
        #expect(calls.map(\.instant) == [Self.at(9, 30), Self.at(9, 30), Self.at(9, 30)])
        // The clock did move while the event waited to be retried.
        #expect(clock.now() > Self.at(9, 30))
    }

    @Test func aFailedEventHoldsUpTheOnesAfterItSoOrderIsKept() async {
        let clock = ManualClock(Self.at(9, 0))
        let recorder = ScriptedRecorder(failing: [.busy])
        let source = FakeSource()
        let feed = pipeline(recorder, clock: clock)
        feed.start(source: source)

        clock.set(Self.at(9, 0))
        source.emit(.lock)
        clock.set(Self.at(9, 5))
        source.emit(.unlock)
        await feed.drain()

        #expect(recorder.calls.map(\.event) == [.lock, .lock, .unlock])
        #expect(recorder.calls.map(\.instant) == [Self.at(9, 0), Self.at(9, 0), Self.at(9, 5)])
    }

    @Test func anEventTheLedgerRefusesIsNotRetriedAndTheNextOneStillGoes() async {
        let clock = ManualClock(Self.at(9, 0))
        let recorder = ScriptedRecorder(failing: [.invalid])
        let source = FakeSource()
        let feed = pipeline(recorder, clock: clock)
        feed.start(source: source)

        source.emit(.sleep)
        source.emit(.wake)
        await feed.drain()
        #expect(recorder.calls.map(\.event) == [.sleep, .wake])
    }

    @Test func retriesStopAtTheLimit() async {
        let clock = ManualClock(Self.at(9, 0))
        let recorder = ScriptedRecorder(failing: Array(repeating: .busy, count: 20))
        let source = FakeSource()
        let feed = pipeline(recorder, clock: clock, retry: PresenceRetry(maxAttempts: 3, delays: [1, 1]))
        feed.start(source: source)

        source.emit(.lock)
        source.emit(.unlock)
        await feed.drain()
        // Three tries for the lock, then three for the unlock: neither blocks the queue for good.
        #expect(recorder.calls.map(\.event) == [.lock, .lock, .lock, .unlock, .unlock, .unlock])
    }

    // MARK: Paused

    @Test func capturePausedDropsEventsUntilItIsResumed() async {
        let clock = ManualClock(Self.at(9, 0))
        let recorder = ScriptedRecorder()
        let source = FakeSource()
        let feed = pipeline(recorder, clock: clock)
        feed.start(source: source)

        source.emit(.sample(idleSeconds: 0, unlocked: true))
        clock.set(Self.at(9, 3))
        feed.setPaused(until: .distantFuture)
        #expect(feed.isPaused(at: clock.now()))

        clock.set(Self.at(9, 4))
        source.emit(.sample(idleSeconds: 0, unlocked: true))
        source.emit(.lock)
        clock.set(Self.at(9, 20))
        feed.setPaused(until: nil)
        #expect(!feed.isPaused(at: clock.now()))
        source.emit(.sample(idleSeconds: 0, unlocked: true))
        await feed.drain()

        // The pause itself closes the open span, at the moment capture stopped.
        #expect(recorder.calls.map(\.event) == [.sample(idleSeconds: 0, unlocked: true), .stop, .sample(idleSeconds: 0, unlocked: true)])
        #expect(recorder.calls.map(\.instant) == [Self.at(9, 0), Self.at(9, 3), Self.at(9, 20)])
    }

    @Test func aPauseEndsByItselfAtItsTime() async {
        let clock = ManualClock(Self.at(9, 0))
        let recorder = ScriptedRecorder()
        let source = FakeSource()
        let feed = pipeline(recorder, clock: clock)
        feed.start(source: source)

        feed.setPaused(until: Self.at(10, 0))
        #expect(feed.pausedUntil == Self.at(10, 0))
        clock.set(Self.at(9, 59))
        source.emit(.lock)
        clock.set(Self.at(10, 0))
        source.emit(.unlock)
        await feed.drain()

        #expect(recorder.calls.map(\.event) == [.stop, .unlock])
        #expect(!feed.isPaused(at: Self.at(10, 0)))
        #expect(feed.pausedUntil == nil)
    }

    @Test func aPauseInThePastIsAResume() {
        let clock = ManualClock(Self.at(9, 0))
        let feed = pipeline(ScriptedRecorder(), clock: clock)
        feed.setPaused(until: .distantFuture)
        feed.setPaused(until: Self.at(8, 0))
        #expect(!feed.isPaused(at: clock.now()))
    }

    // MARK: Stop

    @Test func stoppingDeliversStopAtOnceAndReleasesTheSource() async {
        let clock = ManualClock(Self.at(17, 30))
        let recorder = ScriptedRecorder()
        let source = FakeSource()
        let feed = pipeline(recorder, clock: clock)
        feed.start(source: source)
        #expect(source.started)

        await feed.stop()
        #expect(recorder.calls.map(\.event) == [.stop])
        #expect(recorder.calls.map(\.instant) == [Self.at(17, 30)])
        #expect(source.stopCount == 1)
        // Nothing is accepted after the stop.
        source.emit(.lock)
        await feed.drain()
        #expect(recorder.calls.count == 1)
    }

    // MARK: Sampling cadence

    @Test func samplingBacksOffWhileIdleOrLocked() {
        let active = PresenceSampling.interval(idleSeconds: 0, unlocked: true)
        #expect(active == 30)
        #expect(PresenceSampling.interval(idleSeconds: 120, unlocked: true) == 30)
        #expect(PresenceSampling.interval(idleSeconds: 299, unlocked: true) == 30)
        #expect(PresenceSampling.interval(idleSeconds: 300, unlocked: true) == 60)
        #expect(PresenceSampling.interval(idleSeconds: 4000, unlocked: true) == 60)
        #expect(PresenceSampling.interval(idleSeconds: 0, unlocked: false) == 60)
        // Before the first reading the sampler looks again soon.
        #expect(PresenceSampling.interval(idleSeconds: nil, unlocked: nil) == 30)
    }

    // MARK: Through the real writer

    func home() throws -> DayStoreLoaderTests.Home {
        let home = DayStoreLoaderTests.Home()
        try ConfigStore.save(Config.defaults(timezone: "Asia/Kolkata"), to: home.roots.config)
        return home
    }

    func spans(_ home: DayStoreLoaderTests.Home) throws -> [String] {
        let clock = DayStoreLoaderTests.FixedClock()
        let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
        let store = try SQLiteStore(path: home.roots.database.path, clock: clock, ids: ids, readOnly: true)
        return try store.db.query("SELECT start_at, end_at, source FROM presence_spans ORDER BY start_at, id").map {
            "\($0.text("start_at") ?? "")|\($0.text("end_at") ?? "")|\($0.text("source") ?? "")"
        }
    }

    /// A pipeline on a real writer and store, and a way to feed it events at given times.
    struct Rig {
        let home: DayStoreLoaderTests.Home
        let clock: ManualClock
        let source = FakeSource()
        let feed: PresencePipeline

        init(_ home: DayStoreLoaderTests.Home, start: Date) {
            self.home = home
            clock = ManualClock(start)
            let writer = AppWriter(location: .found(home.roots), clock: clock, poster: SilentPoster())
            feed = PresencePipeline(recorder: writer, clock: clock, sleep: { _ in })
            feed.start(source: source)
        }

        func send(_ event: PresenceEvent, _ time: Date) async {
            clock.set(time)
            source.emit(event)
            await feed.drain()
        }

        /// Input every 30 s from `from` to `to`, as the sampler would see it.
        func active(from: Date, to: Date) async {
            var t = from
            while t <= to {
                await send(.sample(idleSeconds: 0, unlocked: true), t)
                t = t.addingTimeInterval(30)
            }
        }
    }

    @Test func sleepAndWakeCloseAndReopenTheSpanWithTheWakeSource() async throws {
        let home = try home()
        defer { home.remove() }
        let rig = Rig(home, start: Self.at(9, 0))

        await rig.active(from: Self.at(9, 0), to: Self.at(9, 10))
        await rig.send(.sleep, Self.at(9, 10, 20))
        await rig.send(.wake, Self.at(11, 0))
        await rig.active(from: Self.at(11, 0, 5), to: Self.at(11, 29, 35))
        await rig.send(.lock, Self.at(11, 30))

        #expect(
            try spans(home) == [
                "2026-10-29T09:00:00+05:30|2026-10-29T09:10:20+05:30|input",
                "2026-10-29T11:00:05+05:30|2026-10-29T11:30:00+05:30|wake",
            ])
    }

    @Test func pausingClosesTheSpanWhereCaptureStoppedAndResumingStartsANewOne() async throws {
        let home = try home()
        defer { home.remove() }
        let rig = Rig(home, start: Self.at(9, 0))

        await rig.active(from: Self.at(9, 0), to: Self.at(9, 2, 30))
        rig.clock.set(Self.at(9, 3))
        rig.feed.setPaused(until: .distantFuture)
        // Input while paused is not recorded, and the sampler may keep ticking.
        await rig.active(from: Self.at(9, 3, 30), to: Self.at(9, 19, 30))
        rig.clock.set(Self.at(9, 20))
        rig.feed.setPaused(until: nil)
        await rig.active(from: Self.at(9, 20), to: Self.at(9, 39, 30))
        await rig.send(.lock, Self.at(9, 40))

        #expect(
            try spans(home) == [
                "2026-10-29T09:00:00+05:30|2026-10-29T09:03:00+05:30|input",
                "2026-10-29T09:20:00+05:30|2026-10-29T09:40:00+05:30|input",
            ])
    }

    // MARK: Saved state

    @Test func theMachineIsSavedAfterEachEventWhereTheEngineWillFindIt() async throws {
        let home = try home()
        defer { home.remove() }
        let clock = ManualClock(Self.at(9, 0))
        let writer = AppWriter(location: .found(home.roots), clock: clock, poster: SilentPoster())
        let state = PresenceStateFile(roots: home.roots)

        #expect(state.load() == .none)
        _ = try await writer.recordPresence(.sample(idleSeconds: 0, unlocked: true), at: Self.at(9, 0)).get()
        guard case .machine(let open) = state.load() else { Issue.record("expected a saved machine"); return }
        #expect(open.isOpen)

        clock.set(Self.at(9, 10))
        _ = try await writer.recordPresence(.lock, at: Self.at(9, 10)).get()
        guard case .machine(let closed) = state.load() else { Issue.record("expected a saved machine"); return }
        #expect(!closed.isOpen)

        // Private to the owner, like everything else in the store folder.
        let mode = try FileManager.default.attributesOfItem(atPath: state.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func aCrashClosesTheOpenSpanAtItsLastInputOnTheNextLaunch() async throws {
        let home = try home()
        defer { home.remove() }
        let clock = ManualClock(Self.at(9, 0))
        var first: AppWriter? = AppWriter(location: .found(home.roots), clock: clock, poster: SilentPoster())
        for (offset, idle) in [(0, 0.0), (30, 0.0), (60, 0.0), (90, 20.0)] {
            clock.set(Self.at(9, 0).addingTimeInterval(Double(offset)))
            _ = try await first!.recordPresence(.sample(idleSeconds: idle, unlocked: true), at: clock.now()).get()
        }
        // Nothing closed the span: the app died here, with the last input at 09:01:10.
        #expect(try spans(home) == [])
        first = nil

        clock.set(Self.at(11, 0))
        let second = AppWriter(location: .found(home.roots), clock: clock, poster: SilentPoster())
        let written = try await second.recordPresence(.sample(idleSeconds: 0, unlocked: true), at: Self.at(11, 0)).get()
        #expect(written.spans == 1)
        #expect(try spans(home) == ["2026-10-29T09:00:00+05:30|2026-10-29T09:01:10+05:30|input"])
    }

    @Test func withoutASavedStateTheCrashedSpanIsLost() async throws {
        // The contrast that shows the test above is about the saved file: no file, no span.
        let home = try home()
        defer { home.remove() }
        let clock = ManualClock(Self.at(9, 0))
        let first = AppWriter(location: .found(home.roots), clock: clock, poster: SilentPoster())
        _ = try await first.recordPresence(.sample(idleSeconds: 0, unlocked: true), at: Self.at(9, 0)).get()
        try FileManager.default.removeItem(at: PresenceStateFile(roots: home.roots).url)

        clock.set(Self.at(11, 0))
        let second = AppWriter(location: .found(home.roots), clock: clock, poster: SilentPoster())
        _ = try await second.recordPresence(.sample(idleSeconds: 0, unlocked: true), at: Self.at(11, 0)).get()
        #expect(try spans(home) == [])
    }

    @Test func anUnreadableStateStartsFreshInsteadOfFailingTheEvent() async throws {
        let home = try home()
        defer { home.remove() }
        try FileManager.default.createDirectory(at: home.roots.state, withIntermediateDirectories: true)
        try PrivateFile.save(Array("not json".utf8), to: PresenceStateFile(roots: home.roots).url)
        #expect(PresenceStateFile(roots: home.roots).load() == .unreadable)

        let clock = ManualClock(Self.at(9, 0))
        let writer = AppWriter(location: .found(home.roots), clock: clock, poster: SilentPoster())
        _ = try await writer.recordPresence(.sample(idleSeconds: 0, unlocked: true), at: Self.at(9, 0)).get()
        guard case .machine = PresenceStateFile(roots: home.roots).load() else { Issue.record("expected a fresh save"); return }
    }

    @Test func aWriteThatFailsLeavesTheMachineAndSavedStateAsTheyWere() async throws {
        let home = try home()
        defer { home.remove() }
        let clock = ManualClock(Self.at(9, 0))
        let writer = AppWriter(location: .found(home.roots), clock: clock, poster: SilentPoster())
        _ = try await writer.recordPresence(.sample(idleSeconds: 0, unlocked: true), at: Self.at(9, 0)).get()
        let before = PresenceStateFile(roots: home.roots).load()

        // A store that cannot be opened is a failure the pipeline retries; nothing is saved for it.
        let missing = AppWriter(location: .failed(StoreFailure(detail: "no home")), clock: clock, poster: SilentPoster())
        guard case .failure = await missing.recordPresence(.lock, at: Self.at(9, 1)) else { Issue.record("expected a failure"); return }
        #expect(PresenceStateFile(roots: home.roots).load() == before)
    }

    @Test func aWriteThatChangesRowsPostsTheStoreChangedSignal() async throws {
        final class Counting: StoreChangePoster, @unchecked Sendable {
            private let lock = NSLock()
            private var posts = 0
            func postStoreChanged() { lock.withLock { posts += 1 } }
            var count: Int { lock.withLock { posts } }
        }
        let home = try home()
        defer { home.remove() }
        let clock = ManualClock(Self.at(9, 0))
        let poster = Counting()
        let writer = AppWriter(location: .found(home.roots), clock: clock, poster: poster)

        // The first input starts the day, which is a row.
        _ = try await writer.recordPresence(.sample(idleSeconds: 0, unlocked: true), at: Self.at(9, 0)).get()
        #expect(poster.count == 1)
        // Another sample changes only the machine.
        clock.set(Self.at(9, 0, 30))
        _ = try await writer.recordPresence(.sample(idleSeconds: 0, unlocked: true), at: Self.at(9, 0, 30)).get()
        #expect(poster.count == 1)
        // Closing the span writes it.
        clock.set(Self.at(9, 5))
        _ = try await writer.recordPresence(.lock, at: Self.at(9, 5)).get()
        #expect(poster.count == 2)
    }
}
