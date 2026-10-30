import CadenceCore
import Foundation

/// Everything a command needs, built once from the process environment. This is the only place
/// the CLI touches the wall clock, the environment and the real home directory.
struct CLIContext {
    let roots: FileRoots
    let clock: any Clock
    let environment: [String: String]

    static func current() -> CLIContext {
        let environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return CLIContext(
            roots: FileRoots.resolve(environment: environment, userHome: home), clock: SystemClock(),
            environment: environment)
    }

    /// How long a write waits for another process. The hidden `CADENCE_BUSY_TIMEOUT_MS` shortens it for tests.
    var busyTimeoutMilliseconds: Int32 {
        if let text = environment["CADENCE_BUSY_TIMEOUT_MS"], let value = Int32(text), value >= 0 { return value }
        return 3000
    }

    /// Creates the Cadence folders with mode 0700.
    func prepareFolders() throws(CadenceError) {
        for folder in roots.folders {
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw .io("cannot create \(folder.path): \(error.localizedDescription)")
            }
        }
    }

    /// Loads `config.json`, or the defaults when there is none. A missing zone falls back to this Mac's.
    func loadConfig() throws(CadenceError) -> (config: Config, check: ConfigFileCheck) {
        let loaded = try ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier)
        return (loaded.0, loaded.1)
    }

    /// Opens the store read-write, creating and migrating it if needed. Writes no events.
    func openStore(projector: any Projector = LedgerProjector()) throws(CadenceError) -> SQLiteStore {
        try prepareFolders()
        return try SQLiteStore(
            path: roots.database.path, clock: clock, ids: ULIDGenerator(clock: clock, random: SystemRandomSource()),
            projector: projector, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
    }
}
