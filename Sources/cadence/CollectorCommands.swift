import ArgumentParser
import CadenceCore
import Foundation

struct CollectorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collector", abstract: "Built-in collectors. Each prints one envelope/1 on stdout.",
        subcommands: [GitHubCollectorCommand.self, ClaudeCodeTranscriptsCommand.self])
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

struct GitHubCollectorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "github",
        abstract: "Print an envelope of pull requests and reviews, read through gh api graphql.",
        discussion: """
            since and until are days (YYYY-MM-DD, in your profile zone) or RFC 3339 times. gh keeps the login; Cadence never \
            sees a token. On any failure nothing is printed on stdout and the exit status is not zero.
            """)

    @Option(help: "Start of the window: YYYY-MM-DD or an RFC 3339 time.") var since: String
    @Option(help: "End of the window: YYYY-MM-DD (that whole day) or an RFC 3339 time.") var until: String
    @Option(help: "Absolute path to gh. Defaults to the collector's gh in config.json.") var gh: String?
    @Option(help: "Collector name for the envelope header.") var name = "github"

    func run() throws {
        let context = CLIContext.current()
        do {
            let config = try context.loadConfig().config
            let configured = config.collectors.first { $0.name == name } ?? config.collectors.first { $0.builtin == "github" }
            guard let path = gh ?? configured?.gh else {
                throw CadenceError.validation("no gh path: pass --gh /absolute/path/to/gh or set collectors.<name>.gh in config.json")
            }
            var isFolder: ObjCBool = false
            let home = FileManager.default.fileExists(atPath: context.roots.home.path, isDirectory: &isFolder) && isFolder.boolValue
            let collector = GitHubCollector(
                name: name, gh: path, runner: SystemProcessRunner(), environment: context.environment,
                workingDirectory: home ? context.roots.home : FileManager.default.temporaryDirectory,
                config: config, clock: context.clock)
            let bytes = try collector.envelope(since: since, until: until)
            FileHandle.standardOutput.write(Data(bytes))
        } catch let error as CadenceError {
            throw fail(error)
        }
    }
}
