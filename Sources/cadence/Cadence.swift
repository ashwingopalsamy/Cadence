import ArgumentParser
import CadenceCore
import Foundation

@main
struct Cadence: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cadence",
        abstract: "A local work log: ledger, CLI, MCP server and collectors.",
        discussion: "Exit codes: 0 ok, 1 usage, 2 validation, 3 store busy, 4 not found.",
        version: CadenceVersion.app,
        subcommands: [
            LogCommand.self, PlanCommand.self, DayCommand.self, TodayCommand.self, InboxCommand.self,
            QueryCommand.self, StreakCommand.self, StandupCommand.self, ExportCommand.self, RebuildCommand.self,
            DoctorCommand.self, ConfigCommand.self, Dev.self,
        ]
    )

    /// ArgumentParser reports usage errors with status 64. Cadence's contract is 1 for usage and 2 for
    /// validation (docs/SPEC.md section 9.5), so the entry point maps them itself.
    static func main() {
        do {
            if let topic = unknownHelpTopic(Array(CommandLine.arguments.dropFirst())) {
                throw CadenceError.usage("unknown command '\(topic)'; run cadence --help for the list")
            }
            var command = try parseAsRoot()
            try command.run()
        } catch let error as CadenceError {
            Foundation.exit(fail(error).rawValue)
        } catch {
            let code = exitCode(for: error)
            let text = fullMessage(for: error)
            if code == .success {
                if !text.isEmpty { writeLine(text, to: FileHandle.standardOutput) }
                Foundation.exit(0)
            }
            if !text.isEmpty { writeLine(text, to: FileHandle.standardError) }
            Foundation.exit(code == .validationFailure ? 1 : code.rawValue)
        }
    }

    /// `cadence help <word>` for a word that is not a command. ArgumentParser prints the root help and exits 0,
    /// which would tell scripts (and `make check`) that any command exists.
    static func unknownHelpTopic(_ arguments: [String]) -> String? {
        guard arguments.first == "help" else { return nil }
        var level = configuration.subcommands
        for word in arguments.dropFirst() where !word.hasPrefix("-") {
            guard let match = level.first(where: { $0._commandName == word }) else { return word }
            level = match.configuration.subcommands
        }
        return nil
    }
}
