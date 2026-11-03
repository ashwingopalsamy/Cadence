import CadenceCore
import Foundation
import Testing

/// Phase 1 audit fixes that show at the command line.
@Suite struct AuditTests {
    let cli = CLIHome()

    func mode(_ url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue
    }

    // MARK: times

    @Test func futureAndOffDayTimesAreValidationErrors() throws {
        defer { cli.remove() }
        let future = try cli.run(["log", "Did a thing", "--at", "2027-01-01T10:00:00Z"])
        #expect(future.status == 2)
        #expect(future.stderr.contains("--at: 2027-01-01T10:00:00Z is in the future"))
        let off = try cli.run(["log", "Did a thing", "--date", "2026-10-01", "--at", "2026-10-29T10:00:00Z"])
        #expect(off.status == 2)
        #expect(off.stderr.contains("--at: 2026-10-29T10:00:00Z is not on 2026-10-01"))
        let tomorrow = try cli.today().adding(days: 1).description
        #expect(try cli.run(["day", "start", "--date", tomorrow, "--at", "09:00"]).status == 2)
    }

    // MARK: ranges

    @Test func reversedRangesAreValidationEverywhere() throws {
        defer { cli.remove() }
        #expect(try cli.run(["export", "proof", "--from", "2026-10-30", "--to", "2026-10-01", "-o", "-"]).status == 2)
        #expect(try cli.run(["query", "--from", "2026-10-30", "--to", "2026-10-01"]).status == 2)
        #expect(try cli.run(["summary", "--range", "2026-10-30..2026-10-01"]).status == 2)
    }

    // MARK: stand-up copy

    #if !os(macOS)
    @Test func copyNeedsMacOS() throws {
        defer { cli.remove() }
        let result = try cli.run(["standup", "--copy"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("--copy needs macOS"))
        #expect(try cli.run(["standup"]).status == 0)
    }
    #endif

    // MARK: folders

    @Test func existingFoldersAreTightenedToOwnerOnly() throws {
        defer { cli.remove() }
        try FileManager.default.createDirectory(
            at: cli.home.appendingPathComponent("exports"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.home.path)
        #expect(mode(cli.home) == 0o755)
        try cli.run(["today"])
        #expect(mode(cli.home) == 0o700)
        #expect(mode(cli.home.appendingPathComponent("exports")) == 0o700)
    }

    // MARK: dev append

    @Test func devAppendRefusesAStoreWithRealEvents() throws {
        defer { cli.remove() }
        let dev = ["CADENCE_ALLOW_DEV": "1"]
        #expect(try cli.run(["dev", "append", "--count", "2"], environment: dev).status == 0)
        #expect(try cli.run(["dev", "append", "--count", "2"], environment: dev).status == 0)
        try cli.run(["log", "Fixed the flaky test"])
        let refused = try cli.run(["dev", "append", "--count", "2"], environment: dev)
        #expect(refused.status != 0)
        #expect(refused.stderr.contains("real events"))
    }

    // MARK: doctor modes

    @Test func doctorWarnsOnLooseSidecarsBackupsAndExports() throws {
        defer { cli.remove() }
        try cli.run(["rebuild"])
        let files = [
            cli.home.appendingPathComponent("cadence.db-wal"), cli.home.appendingPathComponent("cadence.db-shm"),
            cli.home.appendingPathComponent("backups/old.db"), cli.home.appendingPathComponent("exports/p.json"),
        ]
        for file in files {
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        let result = try cli.run(["doctor"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("warn  database sidecars"))
        #expect(result.stdout.contains("cadence.db-wal") && result.stdout.contains("cadence.db-shm"))
        #expect(result.stdout.contains("warn  private files"))
        #expect(result.stdout.contains("backups/old.db") && result.stdout.contains("exports/p.json"))
    }
}
