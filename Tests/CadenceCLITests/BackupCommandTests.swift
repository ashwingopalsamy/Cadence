import CadenceCore
import Foundation
import Testing

@Suite struct BackupCommandTests {
    let cli = CLIHome()

    var folder: URL { cli.home.appendingPathComponent("backups", isDirectory: true) }

    @Test func backupCreatesThenReportsAlreadyDone() throws {
        defer { cli.remove() }
        try cli.run(["log", "Reviewed the settlement RFC", "--kind", "doc.reviewed"])
        let first = try cli.json(["backup"])
        #expect(first["created"]?.boolValue == true)
        let path = try #require(first["path"]?.stringValue)
        #expect(path.hasPrefix(folder.path))
        #expect(URL(fileURLWithPath: path).lastPathComponent == "cadence-\(first["day"]?.stringValue ?? "").db")
        #expect(try #require(first["events"]?.intValue) >= 2)
        #expect(FileManager.default.fileExists(atPath: path))

        let again = try cli.json(["backup"])
        #expect(again["created"]?.boolValue == false)
        #expect(again["path"]?.stringValue == path)

        let human = try cli.run(["backup"])
        #expect(human.status == 0)
        #expect(human.stdout.contains("already exists"))

        let forced = try cli.json(["backup", "--force"])
        #expect(forced["created"]?.boolValue == true)
    }

    @Test func listShowsBackupsAndVerifyFlagsDamage() throws {
        defer { cli.remove() }
        let empty = try cli.run(["backup", "list"])
        #expect(empty.status == 0)
        #expect(empty.stdout.contains("No backups yet"))

        let made = try cli.json(["backup"])
        let path = try #require(made["path"]?.stringValue)
        let listed = try cli.json(["backup", "list"])
        let files = try #require(listed["backups"]?.arrayValue)
        #expect(files.count == 1)
        #expect(files[0]["path"]?.stringValue == path)
        #expect(files[0]["ok"] == nil)

        let verified = try cli.json(["backup", "list", "--verify"])
        #expect(verified["backups"]?.arrayValue?.first?["ok"]?.boolValue == true)

        try Data("damaged".utf8).write(to: URL(fileURLWithPath: path))
        let bad = try cli.run(["backup", "list", "--verify", "--json"])
        #expect(bad.status == 2)
        #expect(try bad.json()["backups"]?.arrayValue?.first?["ok"]?.boolValue == false)
        #expect(bad.stderr.contains("damaged"))
    }

    @Test func backupsAreKeptPrivate() throws {
        defer { cli.remove() }
        let made = try cli.json(["backup"])
        let path = try #require(made["path"]?.stringValue)
        let file = try FileManager.default.attributesOfItem(atPath: path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}
