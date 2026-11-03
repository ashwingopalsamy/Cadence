import CadenceCore
import Foundation

extension CLIContext {
    /// The store, the config and the journal that applies every rule. Writes the genesis event on first use,
    /// under `actor`.
    func openJournal(actor: Actor = .cli) throws(CadenceError) -> Journal {
        let config = try loadConfig().config
        let store = try openStore()
        return try Journal(
            store: store, config: config, clock: clock, ids: ULIDGenerator(clock: clock, random: SystemRandomSource()),
            actor: actor)
    }
}

extension CLIContext {
    /// A journal for reading, which never starts the ledger: it writes no genesis event, and with no database yet it
    /// reads an empty one in memory, so a read does not create the file either. Used by `cadence mcp` for its reads
    /// and dry runs.
    func openReadJournal(actor: Actor = .mcp) throws(CadenceError) -> Journal {
        let config = try loadConfig().config
        let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
        let store: SQLiteStore
        if FileManager.default.fileExists(atPath: roots.database.path) {
            store = try openStore()
        } else {
            store = try SQLiteStore(path: ":memory:", clock: clock, ids: ids, projector: LedgerProjector())
        }
        return try Journal(store: store, config: config, clock: clock, ids: ids, actor: actor, writesGenesis: false)
    }
}
