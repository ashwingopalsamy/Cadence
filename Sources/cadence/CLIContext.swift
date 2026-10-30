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

    /// Opens the store read-write, creating and migrating it if needed.
    func openStore(actor: Actor = .cli) throws(CadenceError) -> SQLiteStore {
        try prepareFolders()
        let store = try SQLiteStore(
            path: roots.database.path, clock: clock, ids: ULIDGenerator(clock: clock, random: SystemRandomSource()))
        try store.ensureGenesis(profile: [:], actor: actor)
        return store
    }
}
