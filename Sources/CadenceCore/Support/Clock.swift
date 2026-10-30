import Foundation

/// The only source of "now" inside CadenceCore. Core code never calls `Date()`.
public protocol Clock: Sendable {
    func now() -> Date
}

/// A clock that returns the same instant until it is moved. For tests and replays.
public final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date) {
        current = start
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}
