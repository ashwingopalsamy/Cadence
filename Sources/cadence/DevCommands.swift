import ArgumentParser
import CadenceCore

/// Test-only commands. Hidden, and refused unless CADENCE_HOME and CADENCE_ALLOW_DEV=1 are both
/// set and the store holds nothing but genesis and test events, so they can never write test events into a real
/// store by accident.
struct Dev: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Developer checks (hidden).", shouldDisplay: false, subcommands: [DevAppend.self])
}

struct DevAppend: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "append", abstract: "Append test events one transaction at a time (stress test).")

    @Option(help: "How many events to append.") var count: Int = 1
    @Option(help: "A label stored in each event.") var label: String = "stress"

    func run() throws {
        let context = CLIContext.current()
        guard context.environment["CADENCE_ALLOW_DEV"] == "1", !(context.environment["CADENCE_HOME"] ?? "").isEmpty else {
            throw CadenceError.usage("dev commands need CADENCE_HOME and CADENCE_ALLOW_DEV=1")
        }
        let store = try context.openStore(projector: NoProjector())
        let others: Int64
        do {
            others = try store.db.first(
                "SELECT COUNT(*) AS n FROM events WHERE type NOT IN ('ledger.genesis', 'test.stress')")?.int("n") ?? 0
        } catch {
            throw error.cadenceError
        }
        guard others == 0 else {
            throw CadenceError.usage("dev append refuses a store that holds real events; use an empty CADENCE_HOME")
        }
        try store.ensureGenesis(profile: [:], actor: .cli)
        for n in 0..<count {
            try store.append([
                EventDraft(type: "test.stress", subject: "test:\(label)", data: ["label": .string(label), "n": .int(Int64(n))], actor: .cli)
            ])
        }
    }
}
