import Foundation
import Testing

@testable import CadenceCore

@Suite struct CollectorCommandTests {
    @Test func transcriptsCollectorPrintsOneEnvelopeAndKeepsItsStateAt0600() throws {
        let home = CLIHome()
        defer { home.remove() }
        let projects = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vectors/transcripts/projects").path
        let args = [
            "collector", "claude-code-transcripts", "--since", "2026-10-28", "--until", "2026-10-28", "--projects-dir", projects,
        ]
        let result = try home.run(args)
        #expect(result.status == 0)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].contains(#""cadence":"envelope/1""#) && lines[0].contains(#""collector":"claude-code""#))
        #expect(lines[1].contains(#""source_ref":"claude-code:2026-10-28:model-a""#))

        let state = home.home.appendingPathComponent("state/claude-code-transcripts.json")
        let mode = try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)

        let bad = try home.run(["collector", "claude-code-transcripts", "--since", "nope", "--until", "2026-10-28"])
        #expect(bad.status == 2)
    }

    // MARK: - collect

    private func writeConfig(_ home: CLIHome, collectors: String) throws {
        try FileManager.default.createDirectory(at: home.home, withIntermediateDirectories: true)
        let text = #"{"cadence":"config/1","profile":{"timezone":"UTC"},"collectors":{\#(collectors)}}"#
        try Data(text.utf8).write(to: home.configFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.configFile.path)
    }

    @Test func collectRunExplainsARefusalAndExitsZero() throws {
        let home = CLIHome()
        defer { home.remove() }
        try writeConfig(home, collectors: #""github":{"builtin":"github","gh":"/usr/bin/gh","every":"30m"}"#)
        let named = try home.run(["collect", "run", "--name", "github"])
        #expect(named.status == 0)
        #expect(
            named.stdout.contains(
                "github: not run, the command is new or has changed since you approved it. Run cadence collect approve --name github"))
        let due = try home.run(["collect", "run", "--due"])
        #expect(due.status == 0 && due.stdout.contains("github: not run"))
        let none = try home.run(["collect", "run"])
        #expect(none.status == 1)
    }

    @Test func approveNeedsAYesWithoutATerminalThenStatusShowsIt() throws {
        let home = CLIHome()
        defer { home.remove() }
        try writeConfig(home, collectors: #""github":{"builtin":"github","gh":"/usr/bin/gh","every":"30m"}"#)
        let refused = try home.run(["collect", "approve", "--name", "github"])
        #expect(refused.status == 2 && refused.stderr.contains("--yes"))
        #expect(refused.stdout.contains("Collector github will run:"))
        #expect(try home.json(["collect", "status"])["collectors"]?.arrayValue?.first?.objectValue?["approved"] == .bool(false))

        let approved = try home.run(["collect", "approve", "--name", "github", "--yes"])
        #expect(approved.status == 0 && approved.stdout.contains("Approved github."))
        let item = try #require(try home.json(["collect", "status"])["collectors"]?.arrayValue?.first?.objectValue)
        #expect(item["approved"] == .bool(true) && item["due"] == .bool(true) && item["last_run"] == .null)

        let unknown = try home.run(["collect", "approve", "--name", "nope", "--yes"])
        #expect(unknown.status == 4)
    }
}
