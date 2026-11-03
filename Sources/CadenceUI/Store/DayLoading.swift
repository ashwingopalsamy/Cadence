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
    let log: any AppLogSink

    public init(location: StoreLocation, clock: any Clock, log: any AppLogSink = AppLog.system) {
        self.location = location
        self.clock = clock
        self.log = log
    }

    /// Logs the time of the read and, on failure, its kind alone (docs/SPEC.md section 13).
    public func load() -> DayLoad {
        let watch = Stopwatch()
        let load = read()
        switch load {
        case .failed(let failure): log.log(LogRecord(.store, .dayLoad, .failed(LogCode(failure.kind)), millis: watch.millis))
        default: log.log(LogRecord(.store, .dayLoad, .ok, millis: watch.millis))
        }
        return load
    }

    private func read() -> DayLoad {
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
        let manager = FileManager.default
        guard manager.fileExists(atPath: roots.database.path) else {
            // A folder that is there but cannot be entered hides the file: that is a denial, not a first run.
            var isFolder: ObjCBool = false
            if manager.fileExists(atPath: roots.home.path, isDirectory: &isFolder), isFolder.boolValue,
                !manager.isExecutableFile(atPath: roots.home.path) || !manager.isReadableFile(atPath: roots.home.path)
            {
                throw .io("unable to open \(roots.home.path): permission denied")
            }
            throw .notFound(String(localized: "There is no cadence.db in \(roots.home.path)"))
        }
        let config = try ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0
        let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
        let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, readOnly: true)
        // A store from a newer Cadence is not read at all, as it is not written (section 4.6).
        let version: Int
        do { version = try store.db.userVersion() } catch { throw error.cadenceError }
        if Int64(version) > Schema.currentVersion {
            throw .schemaTooNew(found: version, supported: Int(Schema.currentVersion))
        }
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids, actor: .app, writesGenesis: false)
        let today = journal.today()
        let now = clock.now()
        // One snapshot, so the tasks, the day row, the range and the streak agree even while another process writes.
        return try store.transactRead { () throws(CadenceError) -> DayState in
            DayState(context: try journal.dayContext(on: today, at: now))
        }
    }
}
