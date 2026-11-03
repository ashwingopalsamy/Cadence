import CadenceCore
import Foundation
import Testing

@Suite struct PresenceBackfillCommandTests {
    let cli = CLIHome()

    /// A log with two past days, written in GMT so the test does not depend on the Mac's zone.
    func writeLog() throws -> String {
        try FileManager.default.createDirectory(at: cli.home, withIntermediateDirectories: true)
        let path = cli.home.appendingPathComponent("pmset.log")
        let text = """
            2025-03-04 09:00:00 +0000 Wake\tWake from Normal Sleep
            2025-03-04 11:00:00 +0000 Sleep\tEntering Sleep state
            2025-03-04 12:00:00 +0000 DarkWake\tDarkWake from Normal Sleep
            2025-03-04 12:00:30 +0000 Sleep\tEntering Sleep state
            2025-03-05 10:00:00 +0000 Wake\tWake from Normal Sleep
            2025-03-05 10:00:20 +0000 Sleep\tEntering Sleep state
            2025-03-05 13:00:00 +0000 Wake\tWake from Normal Sleep
            2025-03-05 14:30:00 +0000 Sleep\tEntering Sleep state
            not a log line
            2025-03-0 oops

            """
        try text.write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    func config() throws {
        try cli.run(["config", "set", "profile.timezone", "Europe/London"])
    }

    @Test func dryRunPrintsTheTableAndWritesNothing() throws {
        defer { cli.remove() }
        try config()
        let file = try writeLog()
        let run = try cli.run(["presence", "backfill", "--since", "2025-03-01", "--file", file, "--dry-run"])
        #expect(run.status == 0)
        #expect(run.stdout.contains("2025-03-04"))
        #expect(run.stdout.contains("09:00"))
        #expect(run.stdout.contains("14:30"))
        #expect(!run.stdout.contains("\u{2013}") && !run.stdout.contains("\u{2014}"))
        #expect(!FileManager.default.fileExists(atPath: cli.database))
        let json = try cli.json(["presence", "backfill", "--since", "2025-03-01", "--file", file, "--dry-run"])
        #expect(json["dry_run"]?.boolValue == true)
        #expect(json["written"]?.intValue == 0)
        #expect(json["days"]?.arrayValue?.count == 2)
        #expect(json["malformed"]?.intValue == 1)
        #expect(!FileManager.default.fileExists(atPath: cli.database))
    }

    @Test func writesThenSecondRunSkips() throws {
        defer { cli.remove() }
        try config()
        let file = try writeLog()
        let first = try cli.json(["presence", "backfill", "--since", "2025-03-01", "--file", file])
        #expect(first["written"]?.intValue == 2)
        #expect(first["skipped"]?.intValue == 0)
        let second = try cli.json(["presence", "backfill", "--since", "2025-03-01", "--file", file])
        #expect(second["written"]?.intValue == 0)
        #expect(second["skipped"]?.intValue == 2)
        let day = try cli.json(["day", "show", "--date", "2025-03-04"])
        #expect(day["day"]?["first_activity"]?.stringValue == "2025-03-04T09:00:00+00:00")
        #expect(day["day"]?["last_activity"]?.stringValue == "2025-03-04T11:00:00+00:00")
    }

    @Test func sinceLimitsTheDays() throws {
        defer { cli.remove() }
        try config()
        let file = try writeLog()
        let run = try cli.json(["presence", "backfill", "--since", "2025-03-05", "--file", file])
        #expect(run["written"]?.intValue == 1)
    }

    @Test func badArguments() throws {
        defer { cli.remove() }
        try config()
        let file = try writeLog()
        #expect(try cli.run(["presence", "backfill", "--since", "yesterday", "--file", file]).status == 2)
        #expect(try cli.run(["presence", "backfill", "--since", "2999-01-01", "--file", file]).status == 2)
        let missing = try cli.run(["presence", "backfill", "--since", "2025-03-01", "--file", cli.home.path + "/none.log"])
        #expect(missing.status == 1)
        #if !os(macOS)
        let linux = try cli.run(["presence", "backfill", "--since", "2025-03-01"])
        #expect(linux.status == 1)
        #expect(linux.stderr.contains("presence backfill needs macOS"))
        #endif
    }
}
