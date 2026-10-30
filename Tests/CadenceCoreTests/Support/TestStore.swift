import Foundation

@testable import CadenceCore

/// Sequential, readable ids for tests: 01TEST00000000000000000001, …
final class CountingIDs: IdentifierSource, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        let digits = String(n)
        return "01TEST" + String(repeating: "0", count: 20 - digits.count) + digits
    }
}

enum TestStore {
    static func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let start = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21

    static func make(
        path: String = tempDirectory().appendingPathComponent("cadence.db").path,
        clock: ManualClock = ManualClock(start), projector: any Projector = NoProjector()
    ) throws -> SQLiteStore {
        try SQLiteStore(path: path, clock: clock, ids: CountingIDs(), projector: projector)
    }
}
