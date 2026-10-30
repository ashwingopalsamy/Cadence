import CadenceCore
import Foundation

extension CLIContext {
    /// The store, the config and the journal that applies every rule. Writes the genesis event on first use.
    func openJournal() throws(CadenceError) -> Journal {
        let config = try loadConfig().config
        let store = try openStore()
        return try Journal(
            store: store, config: config, clock: clock, ids: ULIDGenerator(clock: clock, random: SystemRandomSource()))
    }
}
