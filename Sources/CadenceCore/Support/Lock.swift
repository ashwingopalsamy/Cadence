import Foundation

/// A small mutex wrapper so Core does not depend on platform-specific lock APIs.
final class NSLockShim: @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
