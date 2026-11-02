import Foundation

/// The store-changed signal (docs/SPEC.md sections 8 and 8.2, spike S6).
///
/// Every process that commits to the store posts it after the commit, and the app listens. It carries
/// no data: a listener reads `PRAGMA data_version` to learn whether anything really changed, so a
/// spurious or lost post costs a poll at worst, never a wrong screen.
public enum StoreChange {
    /// The Darwin notification name. One fixed string for every process: a build made with another
    /// `BUNDLE_PREFIX` still hears the CLI, and an extra wake-up only costs one `data_version` read.
    public static let notificationName = "in.ashwingopalsamy.cadence.store-changed"
}

/// Tells other processes the store changed.
public protocol StoreChangePoster: Sendable {
    func postStoreChanged()
}

/// Posts through the Darwin notify center (CFNotificationCenter, the same notifications as notify(3)),
/// which S6 proved reaches the sandboxed app. Where there is no Darwin notify center (Linux) it does
/// nothing. It has no networking: the notify center is a local Mach service.
public struct DarwinStoreChangePoster: StoreChangePoster {
    public init() {}

    public func postStoreChanged() {
        #if canImport(Darwin)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(StoreChange.notificationName as CFString),
            nil, nil, true)
        #endif
    }
}

/// Where the store-changed signal comes from, so the observer can be tested without the notify center.
public protocol StoreChangeSignal: Sendable {
    /// Starts calling `handler`, on any thread, each time a writer posts. A second call replaces the handler.
    func start(_ handler: @escaping @Sendable () -> Void)
    /// Stops calling the handler. A call already in flight may still land once; the observer ignores it.
    func stop()
}

/// Listens on the Darwin notify center. Does nothing on Linux, where only polling runs.
///
/// The center delivers while the main run loop (or the main dispatch queue) is serviced, which the app
/// does; a process whose main thread is blocked hears nothing, and polling covers it.
public final class DarwinStoreChangeSignal: StoreChangeSignal, @unchecked Sendable {
    private let token = UUID()

    public init() {}

    public func start(_ handler: @escaping @Sendable () -> Void) {
        #if canImport(Darwin)
        DarwinStoreChangeRegistry.shared.add(token, handler)
        #endif
    }

    public func stop() {
        #if canImport(Darwin)
        DarwinStoreChangeRegistry.shared.remove(token)
        #endif
    }

    deinit { stop() }
}

#if canImport(Darwin)
/// One process-wide registration with the notify center, fanning out to the live handlers. A C callback
/// cannot capture, and removing an observer cannot wait for a callback already running, so the center
/// never holds a pointer to anything that can go away: it holds this object, which is never freed.
final class DarwinStoreChangeRegistry: @unchecked Sendable {
    static let shared = DarwinStoreChangeRegistry()

    private let lock = NSLock()
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    private var registered = false

    func add(_ token: UUID, _ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        handlers[token] = handler
        let needsRegistration = !registered
        registered = true
        lock.unlock()
        guard needsRegistration else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in DarwinStoreChangeRegistry.shared.fire() },
            StoreChange.notificationName as CFString, nil, .deliverImmediately)
    }

    func remove(_ token: UUID) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    private func fire() {
        lock.lock()
        let live = Array(handlers.values)
        lock.unlock()
        for handler in live { handler() }
    }
}
#endif
