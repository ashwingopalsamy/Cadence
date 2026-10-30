import CadenceCore
import Foundation
import Testing

/// The CLI scaffold: JSON output, exit codes, CADENCE_HOME and the config commands.
@Suite struct ScaffoldTests {
    let cli = CLIHome()

    @Test func configSetGetRoundTrip() throws {
        defer { cli.remove() }
        let path = try cli.run(["config", "path"])
        #expect(path.status == 0)
        #expect(path.stdout.trimmingCharacters(in: .newlines) == cli.configFile.standardizedFileURL.path)

        #expect(try cli.run(["config", "get", "sounds"]).stdout == "subtle\n")
        let set = try cli.run(["config", "set", "sounds", "full"])
        #expect(set.status == 0)
        #expect(try cli.run(["config", "get", "sounds"]).stdout == "full\n")
        try cli.run(["config", "set", "tickets.titleWindow", "20"])
        let window = try cli.json(["config", "get", "tickets.titleWindow"])
        #expect(window["value"]?.intValue == 20)
        #expect(window["path"]?.stringValue == "tickets.titleWindow")

        let attributes = try FileManager.default.attributesOfItem(atPath: cli.configFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func jsonOutputIsOneCanonicalLine() throws {
        defer { cli.remove() }
        let result = try cli.run(["config", "get", "tickets", "--json"])
        #expect(result.status == 0)
        #expect(result.stdout.hasSuffix("}\n"))
        #expect(result.stdout.dropLast().firstIndex(of: "\n") == nil)
        #expect(try CanonicalJSON.string(try result.json()) + "\n" == result.stdout)
    }

    @Test func cadenceHomeDecidesWhereFilesGo() throws {
        defer { cli.remove() }
        try cli.run(["config", "set", "sounds", "off"])
        #expect(FileManager.default.fileExists(atPath: cli.configFile.path))
    }

    @Test func usageErrorsExitOne() throws {
        defer { cli.remove() }
        #expect(try cli.run(["config", "get"]).status == 1)
        #expect(try cli.run(["config", "bogus"]).status == 1)
        #expect(try cli.run(["nonsense"]).status == 1)
        #expect(try cli.run(["config", "path", "--bogus"]).status == 1)
        #expect(try cli.run(["help", "verify"]).status == 1)
        #expect(try cli.run(["help", "config", "get"]).status == 0)
        #expect(try cli.run(["--help"]).status == 0)
        #expect(try cli.run(["--version"]).status == 0)
    }

    @Test func validationErrorsExitTwo() throws {
        defer { cli.remove() }
        let bad = try cli.run(["config", "set", "sounds", "loud"])
        #expect(bad.status == 2)
        #expect(bad.stderr.hasPrefix("cadence: "))
        #expect(bad.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cli.configFile.path))
        #expect(try cli.run(["config", "set", "cadence", "config/2"]).status == 2)
    }

    @Test func missingKeysExitFour() throws {
        defer { cli.remove() }
        let missing = try cli.run(["config", "get", "no.such.key", "--json"])
        #expect(missing.status == 4)
        #expect(missing.stdout.isEmpty)
        #expect(missing.stderr == "cadence: config key not found: no.such.key\n")
    }

    @Test func aBrokenConfigFileIsReported() throws {
        defer { cli.remove() }
        try FileManager.default.createDirectory(at: cli.home, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: cli.configFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cli.configFile.path)
        #expect(try cli.run(["config", "get", "sounds"]).status == 2)
    }

    @Test func devCommandsAreRefusedWithoutOptIn() throws {
        defer { cli.remove() }
        #expect(try cli.run(["dev", "append"]).status == 1)
        #expect(try cli.run(["dev", "append", "--count", "3"], environment: ["CADENCE_ALLOW_DEV": "1"]).status == 0)
    }
}
