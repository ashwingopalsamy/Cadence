import ArgumentParser
import CadenceCore
import Foundation

struct SpoolCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spool", abstract: "Work with the hook spool (hidden).", shouldDisplay: false,
        subcommands: [SpoolDrainCommand.self])
}

struct SpoolDrainCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drain", abstract: "Turn spooled hook lines into genai.session events.")

    @OptionGroup var output: OutputOptions

    func run() throws {
        try output.run { context in
            let (config, _) = try context.loadConfig()
            let store = try context.openStore()
            let report = try SpoolDrain(roots: context.roots, store: store, config: config, clock: context.clock).drain()
            return Rendered(human: report.summary, json: report.json)
        }
    }
}
