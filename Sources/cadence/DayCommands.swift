import ArgumentParser
import CadenceCore
import Foundation

struct DaySeal: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seal", abstract: "Wrap up a day: carry open tasks to the next workday and seal it.")

    @OptionGroup var output: OutputOptions
    @Option(help: "Day as YYYY-MM-DD. Default: today.") var date: String?

    func run() throws {
        try output.run { context in
            let requested = try Args.date(date)
            let journal = try context.openJournal()
            let result = try journal.seal(requested, actor: .cli)
            var lines = ["Wrapped up \(result.day) at \(Format.clock(result.sealedAt))"]
            if !result.counts { lines.append("This wrap-up came after the grace window, so it does not count for the streak.") }
            if !result.carried.isEmpty {
                lines.append("Carried to \(result.carried[0].task.day):")
                lines += result.carried.map { "  " + $0.task.title + Format.ticket($0.task.ticket, unlessIn: $0.task.title) }
            }
            lines.append(StreakCommand.summary(result.streak))
            return Rendered(human: lines.joined(separator: "\n"), json: result.json)
        }
    }
}

struct StreakCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "streak", abstract: "Consecutive workdays sealed within the grace window.")

    @OptionGroup var output: OutputOptions

    static func summary(_ streak: Streak) -> String {
        var line = "Streak \(streak.current) workday\(streak.current == 1 ? "" : "s"), best \(streak.best)"
        if !streak.pausedBy.isEmpty { line += ", paused by \(streak.pausedBy.map(\.description).joined(separator: ", "))" }
        if streak.atRisk { line += ". A past workday is not wrapped up yet; wrap it up before the end of today to keep the streak." }
        return line
    }

    func run() throws {
        try output.run { context in
            let streak = try context.openJournal().streak(asOf: nil)
            return Rendered(human: Self.summary(streak), json: streak.json)
        }
    }
}

struct StandupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "standup", abstract: "Print the stand-up text, ending in a witness code.")

    @OptionGroup var output: OutputOptions
    @Option(help: "Day as YYYY-MM-DD. Default: today.") var date: String?
    @Flag(help: "Also copy the text to the clipboard (macOS).") var copy = false

    func run() throws {
        try output.run { context in
            #if !os(macOS)
            if copy { throw CadenceError.usage("--copy needs macOS") }
            #endif
            let requested = try Args.date(date)
            let result = try context.openJournal().standup(requested, actor: .cli)
            if copy { try Self.copyToClipboard(result.text, in: context) }
            var json: [String: JSONValue] = ["text": .string(result.text), "code": .string(result.code)]
            if copy { json["copied"] = .bool(true) }
            return Rendered(human: result.text, json: .object(json))
        }
    }

    /// Hands the text to `pbcopy` on its standard input. Argv only, no shell.
    static func copyToClipboard(_ text: String, in context: CLIContext) throws(CadenceError) {
        let request = ProcessRequest(
            executable: "/usr/bin/pbcopy", environment: ["LANG": "en_US.UTF-8"], workingDirectory: context.roots.home,
            stdin: Data(text.utf8), timeout: .seconds(5))
        let result: ProcessResult
        do {
            result = try SystemProcessRunner().run(request)
        } catch {
            throw (error as? CadenceError) ?? .io("pbcopy failed: \(error)")
        }
        guard result.succeeded else { throw .io("pbcopy did not copy the stand-up text") }
    }
}
