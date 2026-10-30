import ArgumentParser
import CadenceCore
import Foundation

/// Demo data (hidden). `cadence demo seed` writes the ACME October demo into an empty CADENCE_HOME and
/// refuses to run without one, so it can never write into a real store.
struct Demo: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Demo data (hidden).", shouldDisplay: false, subcommands: [DemoSeedCommand.self])
}

struct DemoSeedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seed", abstract: "Seed the ACME October demo into an empty CADENCE_HOME.")

    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["CADENCE_HOME"], !home.isEmpty else {
            throw CadenceError.usage("demo seed needs CADENCE_HOME; it never writes to the default store")
        }
        let context = CLIContext.current()
        try context.prepareFolders()
        // The demo clock, not the system clock: the same seed gives the same bytes on any day.
        guard let start = Timestamp.parse(DemoSeed.startInstant) else {
            throw CadenceError.integrity("demo: bad start instant")
        }
        let clock = ManualClock(start)
        if !FileManager.default.fileExists(atPath: context.roots.config.path) {
            try ConfigStore.save(DemoSeed.config(), to: context.roots.config)
        }
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1))
        let store = try SQLiteStore(
            path: context.roots.database.path, clock: clock, ids: ids, projector: LedgerProjector(),
            busyTimeoutMilliseconds: context.busyTimeoutMilliseconds)
        let journal = try Journal(store: store, config: DemoSeed.config(), clock: clock, ids: ids)
        try DemoSeed.seed(into: journal, clock: clock)
        print("Seeded the ACME October demo into \(home)")
    }
}
