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

    /// A collector that really runs: a script that prints an envelope for the window it was asked for.
    private func writeRunnableCollector(_ home: CLIHome, name: String = "oncall") throws {
        try FileManager.default.createDirectory(at: home.home, withIntermediateDirectories: true)
        let script = home.home.appendingPathComponent("\(name).sh")
        let line = #"{"cadence":"envelope/1","collector":"\#(name)","run":"r1","generated_at":"2026-10-01T10:00:00+00:00","window":{"since":"'"$1"'","until":"'"$2"'"}}"#
        try Data("#!/bin/sh\nprintf '%s\\n' '\(line)'\n".utf8).write(to: script)
        let command = #"["/bin/sh","\#(script.path)","{since}","{until}"]"#
        try writeConfig(home, collectors: #""\#(name)":{"command":\#(command)}"#)
        #expect(try home.run(["collect", "approve", "--name", name, "--yes"]).status == 0)
    }

    private func sessionEvents(_ home: CLIHome) throws -> [Event] {
        try home.journal().store.events(after: 0, limit: 10_000).filter { $0.type == "genai.session" }
    }

    private func leaveSession(_ home: CLIHome, _ id: String) throws {
        _ = try home.run(["hook", "session-start"], stdin: #"{"session_id":"\#(id)","cwd":"/x/acme","model":"model-a"}"#)
        _ = try home.run(["hook", "session-end"], stdin: #"{"session_id":"\#(id)","reason":"clear"}"#)
    }

    @Test func collectRunDrainsTheSpoolFirstForDueAndForAName() throws {
        let home = CLIHome()
        defer { home.remove() }
        try writeRunnableCollector(home)
        try leaveSession(home, "s-due")
        #expect(try sessionEvents(home).isEmpty)
        let due = try home.json(["collect", "run", "--due"])
        #expect(due["spool"]?["events_written"]?.intValue == 1)
        let first = try sessionEvents(home)
        #expect(first.count == 1 && first[0].actor == .hook)
        // The collector has no schedule, so nothing else was due.
        #expect(due["runs"]?.arrayValue?.isEmpty == true)

        try leaveSession(home, "s-name")
        let named = try home.run(["collect", "run", "--name", "oncall"])
        #expect(named.status == 0 && named.stdout.contains("oncall: ran for"))
        #expect(try sessionEvents(home).count == 2)
        // A run with nothing waiting drains nothing and says so in the JSON.
        let again = try home.json(["collect", "run", "--name", "oncall"])
        #expect(again["spool"]?["events_written"]?.intValue == 0)
        #expect(again["runs"]?.arrayValue?.first?["outcome"] == "ok")
    }

    @Test func aSpoolDrainThatFailsIsLoggedAndCollectionStillRuns() throws {
        let home = CLIHome()
        defer { home.remove() }
        try writeRunnableCollector(home)
        try leaveSession(home, "s-1")
        // The drain cannot save its progress: its state file is in the way.
        try FileManager.default.createDirectory(
            at: home.home.appendingPathComponent("state/spool-drain.json"), withIntermediateDirectories: true)
        let named = try home.run(["collect", "run", "--name", "oncall"])
        #expect(named.status == 0)
        #expect(named.stderr.contains("spool drain failed"), "\(named.stderr)")
        #expect(named.stdout.contains("oncall: ran for"))
        let json = try home.json(["collect", "run", "--name", "oncall"])
        #expect(json["spool"]?["error"]?.stringValue?.isEmpty == false)
        #expect(json["runs"]?.arrayValue?.first?["outcome"] == "ok")
        let due = try home.run(["collect", "run", "--due"])
        #expect(due.status == 0 && due.stderr.contains("spool drain failed"))
    }

    @Test func sinceAndUntilRunThatExactWindowInSevenDayChunks() throws {
        let home = CLIHome()
        defer { home.remove() }
        try writeRunnableCollector(home)
        let one = try home.json(["collect", "run", "--name", "oncall", "--since", "2026-10-01", "--until", "2026-10-03"])
        let runs = try #require(one["runs"]?.arrayValue)
        #expect(runs.count == 1 && runs[0]["window"]?["since"] == "2026-10-01" && runs[0]["window"]?["until"] == "2026-10-03")
        let long = try home.json(["collect", "run", "--name", "oncall", "--since", "2026-10-01", "--until", "2026-10-15"])
        let windows = (long["runs"]?.arrayValue ?? []).map { "\($0["window"]?["since"]?.stringValue ?? "")..\($0["window"]?["until"]?.stringValue ?? "")" }
        #expect(windows == ["2026-10-01..2026-10-07", "2026-10-08..2026-10-14", "2026-10-15..2026-10-15"])
        let human = try home.run(["collect", "run", "--name", "oncall", "--since", "2026-10-01", "--until", "2026-10-03"])
        #expect(human.stdout.contains("oncall: ran for 2026-10-01 to 2026-10-03"))
    }

    @Test func sinceAndUntilAreCheckedBeforeAnythingRuns() throws {
        let home = CLIHome()
        defer { home.remove() }
        try writeRunnableCollector(home)
        let today = try home.today()
        let tomorrow = today.adding(days: 1).description
        let cases: [([String], String)] = [
            (["--since", "2026-10-05", "--until", "2026-10-01"], "--since 2026-10-05 is after --until 2026-10-01"),
            (["--since", "2026-10-01", "--until", tomorrow], "--until \(tomorrow) is in the future"),
            (["--since", "1999-12-31", "--until", "2026-10-01"], "--since 1999-12-31 is before 2000-01-01"),
            (["--since", "yesterday", "--until", "2026-10-01"], "--since"),
            (["--since", "2026-10-01"], "--since and --until go together"),
            (["--until", "2026-10-01"], "--since and --until go together"),
            (["--since", "2026-10-01", "--until", "2026-10-02", "--backfill-from", "2026-10-01"], "cannot be combined"),
        ]
        for (arguments, message) in cases {
            let result = try home.run(["collect", "run", "--name", "oncall"] + arguments)
            #expect(result.status != 0, "\(arguments)")
            #expect(result.stderr.contains(message), "\(arguments): \(result.stderr)")
        }
        let due = try home.run(["collect", "run", "--due", "--since", "2026-10-01", "--until", "2026-10-02"])
        #expect(due.status == 1 && due.stderr.contains("--due cannot be combined"))
        let noName = try home.run(["collect", "run", "--since", "2026-10-01", "--until", "2026-10-02"])
        #expect(noName.status == 1)
        // Nothing ran for any of them: the collector has no run on record.
        let status = try home.json(["collect", "status"])
        #expect(status["collectors"]?.arrayValue?.first?["last_run"] == .null)
    }

    @Test func aBackfillStartIsCheckedToo() throws {
        let home = CLIHome()
        defer { home.remove() }
        try writeRunnableCollector(home)
        let tomorrow = try home.today().adding(days: 1).description
        for (start, message) in [("1999-12-31", "is before 2000-01-01"), (tomorrow, "is in the future")] {
            let result = try home.run(["collect", "run", "--name", "oncall", "--backfill-from", start])
            #expect(result.status == 2 && result.stderr.contains(message), "\(start): \(result.stderr)")
        }
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
