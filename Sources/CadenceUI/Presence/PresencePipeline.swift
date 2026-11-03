import CadenceCore
import Foundation

/// Where presence events end up: the app's writer, or a fake in tests.
public protocol PresenceRecording: Sendable {
    /// `instant` is when the event happened. A retry passes the same one.
    func recordPresence(_ event: PresenceEvent, at instant: Date) async -> Result<PresenceWrite, StoreFailure>
}

extension AppWriter: PresenceRecording {}

/// How an event the store would not take is tried again (docs/SPEC.md section 8.4).
public struct PresenceRetry: Sendable, Equatable {
    /// Tries in all, the first included.
    public var maxAttempts: Int
    /// Seconds to wait before the second try, the third and so on. The last one repeats.
    public var delays: [TimeInterval]

    public static let standard = PresenceRetry(maxAttempts: 4, delays: [2, 10, 30])

    public init(maxAttempts: Int, delays: [TimeInterval]) {
        self.maxAttempts = maxAttempts
        self.delays = delays
    }

    /// A busy, unreadable or full store may come back. A refusal by the ledger or a newer schema will not.
    func retries(_ kind: StoreFailure.Kind) -> Bool {
        switch kind {
        case .invalid, .newerSchema: false
        default: true
        }
    }

    func delay(afterAttempt attempt: Int) -> TimeInterval {
        guard !delays.isEmpty else { return 0 }
        return delays[min(max(attempt - 1, 0), delays.count - 1)]
    }
}

/// How often the idle sampler looks (docs/SPEC.md section 8.4): every 30 s while input is recent enough for a span to
/// be open, every 60 s once the Mac has been idle for the close threshold or is locked. Nothing is sampled while
/// the Mac sleeps, so that is the whole idle cost: one cheap reading a minute.
public enum PresenceSampling {
    public static let activeInterval: TimeInterval = 30
    public static let idleInterval: TimeInterval = 60

    public static func interval(idleSeconds: Double?, unlocked: Bool?, rules: PresenceRules = .standard) -> TimeInterval {
        if unlocked == false { return idleInterval }
        guard let idleSeconds else { return activeInterval }
        return idleSeconds < rules.closeIdle ? activeInterval : idleInterval
    }
}

/// Events from the Mac to the writer, in order, each at the time it happened.
///
/// Sources call `submit` from any thread. It reads the clock and queues the event under one lock, so the order of the
/// queue is the order of the times. One consumer takes them one at a time: it hands each to the recorder with its own
/// time, and a failed write is tried again with that same time while the events behind it wait. A retry therefore
/// cannot move an event to the time of the retry, and two events cannot pass each other.
///
/// Capture paused (docs/SPEC.md section 5.2): while paused, events are dropped, and pausing closes the open span at
/// that moment, so a pause of a few minutes is not counted as presence.
public final class PresencePipeline: @unchecked Sendable {
    private enum Item: Sendable {
        case event(PresenceEvent, Date)
        case barrier(CheckedContinuation<Void, Never>)
    }

    private let clock: any Clock
    private let lock = NSLock()
    private var paused: Date?
    private var source: (any PresenceEventSource)?
    private let continuation: AsyncStream<Item>.Continuation
    private let consumer: Task<Void, Never>

    public init(
        recorder: any PresenceRecording, clock: any Clock, retry: PresenceRetry = .standard,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        log: any AppLogSink = AppLog.system
    ) {
        self.clock = clock
        let (stream, continuation) = AsyncStream.makeStream(of: Item.self)
        self.continuation = continuation
        consumer = Task.detached(priority: .utility) {
            for await item in stream {
                switch item {
                case .event(let event, let instant):
                    await Self.deliver(event, at: instant, to: recorder, retry: retry, sleep: sleep, log: log)
                case .barrier(let waiting):
                    waiting.resume()
                }
            }
        }
    }

    private static func deliver(
        _ event: PresenceEvent, at instant: Date, to recorder: any PresenceRecording, retry: PresenceRetry,
        sleep: @Sendable (TimeInterval) async -> Void, log: any AppLogSink
    ) async {
        var attempt = 1
        while true {
            let watch = Stopwatch()
            switch await recorder.recordPresence(event, at: instant) {
            case .success:
                return
            case .failure(let failure):
                // The writer logs every try; this line says what became of an event that did not go in.
                let code = LogCode(failure.kind)
                guard attempt < retry.maxAttempts, retry.retries(failure.kind) else {
                    log.log(LogRecord(.presence, .presenceDeliver, .gaveUp(code, attempt: attempt), millis: watch.millis))
                    return
                }
                log.log(LogRecord(.presence, .presenceDeliver, .retry(code, attempt: attempt), millis: watch.millis))
                await sleep(retry.delay(afterAttempt: attempt))
                attempt += 1
            }
        }
    }

    // MARK: Events

    /// Starts the source. Its events go to `submit`.
    public func start(source: any PresenceEventSource) {
        lock.withLock { self.source = source }
        source.start { [weak self] event in self?.submit(event) }
    }

    /// Queues one event at the time the clock reads now. Dropped while capture is paused, except a stop.
    public func submit(_ event: PresenceEvent) {
        lock.withLock {
            let now = clock.now()
            if event != .stop, let until = paused {
                if now < until { return }
                paused = nil
            }
            continuation.yield(.event(event, now))
        }
    }

    /// Resolves once every event queued before the call has been handled, or given up on.
    public func drain() async {
        await withCheckedContinuation { waiting in
            if case .terminated = continuation.yield(.barrier(waiting)) { waiting.resume() }
        }
    }

    /// Stops the source, closes the open span at this moment and waits for the queue to empty. For the app quitting.
    public func stop() async {
        let current = lock.withLock { () -> (any PresenceEventSource)? in
            defer { source = nil }
            return source
        }
        current?.stop()
        submit(.stop)
        await drain()
        continuation.finish()
    }

    /// `stop()` for a place that cannot wait asynchronously, such as `applicationWillTerminate`. Gives up after
    /// `timeout` seconds: the next launch closes the span at its last input from the saved state.
    public func stopAndWait(timeout: TimeInterval = 1) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await self.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    // MARK: Capture paused

    /// Pauses capture until `until`, or until `setPaused(until: nil)` when `until` is `.distantFuture`. A time that has
    /// passed resumes. Pausing closes the open span now.
    public func setPaused(until: Date?) {
        lock.withLock {
            let now = clock.now()
            guard let until, until > now else {
                paused = nil
                return
            }
            if paused.map({ now >= $0 }) ?? true { continuation.yield(.event(.stop, now)) }
            paused = until
        }
    }

    /// When the pause ends, or nil when capture is not paused.
    public var pausedUntil: Date? {
        lock.withLock { paused.flatMap { clock.now() < $0 ? $0 : nil } }
    }

    public func isPaused(at instant: Date) -> Bool {
        lock.withLock { paused.map { instant < $0 } ?? false }
    }
}
