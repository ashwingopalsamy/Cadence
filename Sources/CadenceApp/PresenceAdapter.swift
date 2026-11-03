// The presence adapter (docs/SPEC.md section 8.4): the Mac's workspace notifications and idle time, fed to the
// presence engine through one pipeline. The pipeline, the retry rule and the saved state are in CadenceUI, where the
// tests are; this file is the part that only runs on the Mac. It reads idle seconds and session state, never keys,
// apps or window titles (section 13).
import AppKit
import CadenceCore
import CadenceUI
import CoreGraphics

/// What the Mac says about input and the session, behind a protocol so the sampler can be told something else.
protocol IdleReading: Sendable {
    /// Seconds since the last keyboard or pointer input of any kind.
    func secondsSinceLastInput() -> Double
    /// Whether the session is on the console and not locked. Nil when macOS does not say.
    func sessionUnlocked() -> Bool?
}

struct SystemIdleReader: IdleReading {
    /// `kCGAnyInputEventType`. `.null` is `kCGEventNull`, not an idle measure (docs/SPIKES.md S4 and V6).
    private static let anyInput = CGEventType(rawValue: ~0)!

    func secondsSinceLastInput() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput)
    }

    func sessionUnlocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        let onConsole = session["kCGSessionOnConsoleKey"] as? Bool ?? false
        let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        return onConsole && !locked
    }
}

/// Turns workspace notifications and an idle sampler into `PresenceEvent`s.
///
/// - `willSleep` is `.sleep`, `didWake` is `.wake`, session resign and become active are `.sessionResigned` and
///   `.sessionActive`, and `willPowerOff` is `.powerOff`. Power off is unproven (docs/SPIKES.md S4): if it never
///   arrives, quitting delivers `.stop` and a crash is closed from the saved state at the last input.
/// - `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` on the distributed center are `.lock` and `.unlock`.
/// - Screens sleeping or waking are not presence (the engine has no event for them), so each one only takes a sample
///   now: a display woken by a key press opens its span at that key, not up to a minute later.
/// - The sampler is one timer that sets its own next deadline: 30 s while input is recent, 60 s when idle or locked
///   (`PresenceSampling`), with leeway so the system can coalesce the wake-ups.
///
/// Notifications are delivered on the thread that posts them and handed on at once, so each event takes its time when
/// it arrives. Sampling runs on its own serial queue.
final class WorkspacePresenceSource: PresenceEventSource, @unchecked Sendable {
    private let reader: any IdleReading
    private let queue = DispatchQueue(label: "in.ashwingopalsamy.cadence.presence", qos: .utility)
    private let lock = NSLock()
    private var deliver: ((PresenceEvent) -> Void)?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var timer: DispatchSourceTimer?

    init(reader: any IdleReading = SystemIdleReader()) {
        self.reader = reader
    }

    func start(_ deliver: @escaping (PresenceEvent) -> Void) {
        lock.withLock { self.deliver = deliver }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.willSleepNotification, as: .sleep)
        observe(workspace, NSWorkspace.didWakeNotification, as: .wake)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, as: .sessionResigned)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, as: .sessionActive)
        observe(workspace, NSWorkspace.willPowerOffNotification, as: .powerOff)
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), as: .lock)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), as: .unlock)
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.sampleSoon() }
            lock.withLock { observers.append((workspace, token)) }
        }
        // The first reading is at launch, so a user already at the keyboard starts a span now.
        sampleSoon()
    }

    func stop() {
        let (centers, current) = lock.withLock { () -> ([(center: NotificationCenter, token: NSObjectProtocol)], DispatchSourceTimer?) in
            defer {
                deliver = nil
                observers = []
                timer = nil
            }
            return (observers, timer)
        }
        for (center, token) in centers { center.removeObserver(token) }
        current?.cancel()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, as event: PresenceEvent) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.send(event) }
        lock.withLock { observers.append((center, token)) }
    }

    private func send(_ event: PresenceEvent) {
        lock.withLock { deliver }?(event)
    }

    private func sampleSoon() {
        queue.async { [weak self] in self?.sample() }
    }

    /// Reads idle time and the session, delivers a sample, and sets the next deadline.
    private func sample() {
        guard lock.withLock({ deliver != nil }) else { return }
        let idle = reader.secondsSinceLastInput()
        let unlocked = reader.sessionUnlocked()
        if let unlocked { send(.sample(idleSeconds: idle, unlocked: unlocked)) }
        schedule(after: PresenceSampling.interval(idleSeconds: idle, unlocked: unlocked))
    }

    private func schedule(after interval: TimeInterval) {
        lock.withLock {
            guard deliver != nil else { return }
            let next = timer ?? DispatchSource.makeTimerSource(queue: queue)
            if timer == nil {
                next.setEventHandler { [weak self] in self?.sample() }
                next.resume()
                timer = next
            }
            next.schedule(deadline: .now() + interval, repeating: .never, leeway: .milliseconds(Int(interval * 100)))
        }
    }
}

/// The app's presence: the Mac's events and idle sampler feeding the writer, and the "Capture paused" switch.
final class PresenceAdapter: @unchecked Sendable {
    private let pipeline: PresencePipeline
    private let source: WorkspacePresenceSource

    init(writer: AppWriter, clock: any Clock, source: WorkspacePresenceSource = WorkspacePresenceSource()) {
        pipeline = PresencePipeline(recorder: writer, clock: clock)
        self.source = source
    }

    /// Starts listening and sampling.
    func start() {
        pipeline.start(source: source)
    }

    /// Closes the open span now and stops. For `applicationWillTerminate`; waits at most a second.
    func stop() {
        pipeline.stopAndWait()
    }

    /// Pauses capture until `until` (`.distantFuture` until resumed) or resumes it with nil. Pausing closes the open
    /// span at that moment, and events are dropped until the pause ends.
    func setPaused(until: Date?) {
        pipeline.setPaused(until: until)
    }

    /// When the pause ends, or nil when capture is running. Feeds `AppSignals.paused`.
    var pausedUntil: Date? { pipeline.pausedUntil }
    var isPaused: Bool { pausedUntil != nil }
}
