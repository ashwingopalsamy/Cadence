import ArgumentParser
import CadenceCore

@main
struct Cadence: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cadence",
        abstract: "A local work log: ledger, CLI, MCP server and collectors.",
        version: CadenceVersion.app
    )
}
