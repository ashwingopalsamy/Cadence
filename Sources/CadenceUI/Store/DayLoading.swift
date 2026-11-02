import CadenceCore
import Foundation

/// Reads today from wherever the store is. A read blocks on the disk, so it runs off the main thread;
/// the model calls it from a background queue and publishes the result on the main actor.
public protocol DayLoading: Sendable {
    /// `.loaded` or `.failed`, never `.loading`.
    func load() -> DayLoad
}

/// Reads today through `Journal` on a fresh read-only connection, one per load. It never opens the store
/// for writing, so it cannot start a ledger or migrate one, and a failure is reported as the error state:
/// it never tries another location. If the store is at the place it was told to read, it reads it; if not,
/// that is the answer.
public struct DayStoreLoader: DayLoading {
    public let location: StoreLocation
    public let clock: any Clock

    public init(location: StoreLocation, clock: any Clock) {
        self.location = location
        self.clock = clock
    }

    public func load() -> DayLoad {
        let roots: FileRoots
        switch location {
        case .found(let found): roots = found
        case .failed(let failure): return .failed(failure)
        }
        do {
            return .loaded(try read(roots))
        } catch {
            return .failed(StoreFailure(error))
        }
    }

    private func read(_ roots: FileRoots) throws(CadenceError) -> DayState {
        guard FileManager.default.fileExists(atPath: roots.database.path) else {
            throw .notFound("There is no cadence.db in \(roots.home.path)")
        }
        let config = try ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0
        let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
        let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, readOnly: true)
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids, actor: .app, writesGenesis: false)
        let today = journal.today()
        // One snapshot, so the tasks, the day row and the streak agree even while another process writes.
        return try store.transactRead { () throws(CadenceError) -> DayState in
            DayState(day: today, view: try journal.dayView(today), streak: try? journal.streak())
        }
    }
}
