import ArgumentParser
import CadenceCore
import Foundation

struct CollectorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collector", abstract: "Built-in collectors. Each prints one envelope/1 on stdout.",
        subcommands: [ClaudeCodeTranscriptsCommand.self])
}

struct ClaudeCodeTranscriptsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude-code-transcripts",
        abstract: "Print Claude Code token usage per day and model as an envelope.",
        discussion: "Reads transcripts on this Mac only. Nothing leaves the machine.")

    @Option(name: .long, help: "First day, YYYY-MM-DD.") var since: String
    @Option(name: .long, help: "Last day, YYYY-MM-DD.") var until: String
    @Option(name: .long, help: "Collector name in the header.") var name = "claude-code"
    @Option(name: .customLong("projects-dir"), help: "Transcripts folder. Default: claudeCode.projectsDir in config.")
    var projectsDir: String?

    func run() throws {
        do {
            let context = CLIContext.current()
            let from = try Args.required(since, option: "since")
            let to = try Args.required(until, option: "until")
            guard from <= to else { throw CadenceError.validation("--since must not be after --until") }
            let config = try context.loadConfig().config
            guard let zone = TimeZone(identifier: config.profile.timezone) else {
                throw CadenceError.validation("profile.timezone: '\(config.profile.timezone)' is not a time zone")
            }
            let collector = TranscriptsCollector(
                projectsDir: projectsDir ?? config.claudeCode.projectsDir,
                userHome: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                stateFile: context.roots.state.appendingPathComponent("claude-code-transcripts.json"), zone: zone,
                boundary: config.dayBoundary, prices: config.genai.prices)
            let run = ULIDGenerator(clock: context.clock, random: SystemRandomSource()).next()
            let output = try collector.run(name: name, runID: run, now: context.clock.now(), since: from, until: to)
            FileHandle.standardOutput.write(Data(output.envelope))
        } catch let error as CadenceError {
            throw fail(error)
        }
    }
}
