import CadenceCore
import Dispatch
import Foundation

/// Reads the store through `Journal` on a fresh read-only connection, one per read, as `DayStoreLoader` does. It never
/// opens the store for writing, so it cannot start a ledger or migrate one, and it never tries another location.
/// Every read runs inside one read transaction, so what it returns is one snapshot of the ledger.
public struct JournalReader: Sendable {
    public let location: StoreLocation
    public let clock: any Clock

    public init(location: StoreLocation, clock: any Clock) {
        self.location = location
        self.clock = clock
    }

    public func read<Value>(_ body: (Journal) throws(CadenceError) -> Value) -> Result<Value, StoreFailure> {
        let roots: FileRoots
        switch location {
        case .found(let found): roots = found
        case .failed(let failure): return .failure(failure)
        }
        do throws(CadenceError) {
            guard FileManager.default.fileExists(atPath: roots.database.path) else {
                throw .notFound(String(localized: "There is no cadence.db in \(roots.home.path)"))
            }
            let config = try ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0
            let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
            let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, readOnly: true)
            let journal = try Journal(store: store, config: config, clock: clock, ids: ids, actor: .app, writesGenesis: false)
            return .success(try store.transactRead { () throws(CadenceError) -> Value in try body(journal) })
        } catch {
            return .failure(StoreFailure(error))
        }
    }

    /// The same read on `queue`, so the main thread never waits on the disk.
    func read<Value: Sendable>(
        on queue: DispatchQueue, _ body: @escaping @Sendable (Journal) throws(CadenceError) -> Value
    ) async -> Result<Value, StoreFailure> {
        let reader = self
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: reader.read(body)) }
        }
    }
}
