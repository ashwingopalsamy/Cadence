import CadenceCore
import Foundation

extension CLIHome {
    /// A journal on the same store, for setting up what the CLI cannot write (agent proposals).
    func journal() throws -> Journal {
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let clock = WallClock()
        let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
        let store = try SQLiteStore(path: database, clock: clock, ids: ids, projector: LedgerProjector())
        let config = Config.defaults(timezone: TimeZone.current.identifier)
        return try Journal(store: store, config: config, clock: clock, ids: ids)
    }
}
