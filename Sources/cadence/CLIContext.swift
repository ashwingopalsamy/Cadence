import CadenceCore
import Foundation

/// Everything a command needs, built once from the process environment. This is the only place
/// the CLI touches the wall clock, the environment and the real home directory.
struct CLIContext {
    let roots: FileRoots
    let clock: any Clock
    let environment: [String: String]
    /// The user's home folder, where `~/.claude`, `~/.claude.json` and `~/.local/bin` live. It is `HOME` when that
    /// is an absolute path, so tests and `HOME=... cadence setup claude-code` act on a throwaway home.
    let userHome: URL

    static func current() -> CLIContext {
        let environment = ProcessInfo.processInfo.environment
        let home = userHomeFolder(environment)
        return CLIContext(
            roots: FileRoots.resolve(environment: environment, userHome: home), clock: SystemClock(),
            environment: environment, userHome: home)
    }

    static func userHomeFolder(_ environment: [String: String]) -> URL {
        if let explicit = environment["HOME"], explicit.hasPrefix("/") {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// How long a write waits for another process. The hidden `CADENCE_BUSY_TIMEOUT_MS` shortens it for tests.
    var busyTimeoutMilliseconds: Int32 {
        if let text = environment["CADENCE_BUSY_TIMEOUT_MS"], let value = Int32(text), value >= 0 { return value }
        return 3000
    }

    /// Creates the Cadence folders with mode 0700. With `repair`, a folder that already exists and belongs to
    /// this user is tightened to 0700 too; a folder owned by someone else is left alone and `doctor` reports it.
    func prepareFolders(repair: Bool = true) throws(CadenceError) {
        let manager = FileManager.default
        for folder in roots.folders {
            do {
                try manager.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard repair, let attributes = try? manager.attributesOfItem(atPath: folder.path),
                    let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == geteuid(),
                    let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o7777 != 0o700
                else { continue }
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            } catch {
                throw .io("cannot prepare \(folder.path): \(error.localizedDescription)")
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
