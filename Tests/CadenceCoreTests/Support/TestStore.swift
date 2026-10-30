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
    /// One folder per test process, removed when the process exits, so runs never leave stores behind in /tmp.
    static let root: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-tests-\(getpid())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestStore.root) }
        return root
    }()

    static func tempDirectory(_ prefix: String = "store") -> URL {
        let dir = root.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
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
