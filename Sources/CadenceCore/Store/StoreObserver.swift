import Foundation

/// Reads `PRAGMA data_version` on a connection of its own, which is what makes the value mean something:
/// it changes when any other connection commits, and never for this connection's own writes. The
/// connection is opened on first use, and again after the store file is replaced (a restore) or
/// disappears, so a missing store reads as `.unreadable` until it exists.
public final class StoreVersionProbe: StoreVersionSource, @unchecked Sendable {
    private struct FileIdentity: Equatable {
        var device: UInt64
        var inode: UInt64
    }

    private let path: String
    private let lock = NSLock()
    private var db: SQLiteDatabase?
    private var identity: FileIdentity?

    public init(path: String) {
        self.path = path
    }

    public func read() -> StoreReading {
        lock.lock()
        defer { lock.unlock() }
        var info = stat()
        guard stat(path, &info) == 0 else {
            db = nil
            identity = nil
            return .unreadable
        }
        let current = FileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(truncatingIfNeeded: info.st_ino))
        // A different file under the same name has its own change counter; the old connection would never move.
        if current != identity { db = nil }
        do {
            let connection = try db ?? SQLiteDatabase(path: path, readOnly: true)
            let version = try connection.dataVersion()
            db = connection
            identity = current
            return .version(version)
        } catch {
            db = nil
            identity = nil
            return .unreadable
        }
    }
}

/// Watches the store and calls `onChange` when it has changed (docs/SPEC.md sections 8.2 and 8.7, S6).
///
/// A store-changed notification wakes it, it reads `data_version`, and it calls `onChange` once per real
/// change however many writes made it. Polling is the fallback if a notification is lost: every 2 s while
/// visible, every 30 s otherwise. The first check runs as soon as `start` is called and calls `onChange`
/// too, so the owner needs no separate initial load, and no write can fall between the two.
///
/// Everything runs on one private queue and one timer that is re-armed for the next deadline, so an idle
/// observer wakes only for its slow poll. `onChange` runs on that queue: hand the work off and return.
/// The decisions live in `StoreChangeDetector`.
public final class StoreObserver: @unchecked Sendable {
    private let source: any StoreVersionSource
    private let clock: any Clock
    private let timing: StoreWatchTiming
    private let signal: any StoreChangeSignal
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "in.ashwingopalsamy.cadence.store-observer", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()

    // Touched only on `queue`.
    private var detector: StoreChangeDetector?
    private var timer: DispatchSourceTimer?
    private var visible: Bool

    public init(
        source: any StoreVersionSource, clock: any Clock, timing: StoreWatchTiming = .standard, visible: Bool = false,
        signal: any StoreChangeSignal = DarwinStoreChangeSignal(), onChange: @escaping @Sendable () -> Void
    ) {
        self.source = source
        self.clock = clock
        self.timing = timing
        self.visible = visible
        self.signal = signal
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        timer?.cancel()
        signal.stop()
    }

    /// Starts listening and makes the first check. Does nothing if already started.
    public func start() {
        queue.sync {
            guard timer == nil else { return }
            detector = StoreChangeDetector(timing: timing, visible: visible, now: clock.now())
            signal.start { [weak self] in self?.signalled() }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.fire() }
            self.timer = timer
            arm()
            timer.resume()
        }
    }

    /// Stops for good. When it returns, `onChange` is not running and will not run again.
    public func stop() {
        let teardown = {
            self.timer?.cancel()
            self.timer = nil
            self.detector = nil
            self.signal.stop()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            teardown()
        } else {
            queue.sync(execute: teardown)
        }
    }

    /// Tells the observer whether a Cadence surface is on screen. Showing one checks at once.
    public func setVisible(_ visible: Bool) {
        queue.async {
            self.visible = visible
            guard self.detector != nil else { return }
            self.detector?.setVisible(visible, at: self.clock.now())
            self.arm()
        }
    }

    private func signalled() {
        queue.async {
            guard self.detector != nil else { return }
            self.detector?.signal(at: self.clock.now())
            self.arm()
        }
    }

    private func fire() {
        guard detector != nil else { return }
        let changed = detector?.wake(at: clock.now(), read: source.read) ?? false
        arm()
        if changed { onChange() }
    }

    /// Points the timer at the detector's next deadline. The leeway lets the system batch the slow poll
    /// with other wake-ups; the short coalescing window gets a small one.
    private func arm() {
        guard let detector, let timer else { return }
        let delay = max(0, detector.nextWake.timeIntervalSince(clock.now()))
        let leeway = delay >= 1 ? min(delay * 0.1, 3) : 0.01
        timer.schedule(deadline: .now() + delay, leeway: .nanoseconds(Int(leeway * 1_000_000_000)))
    }
}
