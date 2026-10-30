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
