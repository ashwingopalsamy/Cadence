import Foundation
import Testing

@testable import CadenceCore

/// `cadence setup claude-code` and the doctor checks that go with it, against a throwaway HOME. The harness points
/// HOME at a temporary folder for every run, so nothing here reads or writes the real one.
@Suite struct SetupCommandTests {
    static let settingsPath = ".claude/settings.json"

    /// A folder with a pretend `claude` that records its arguments and writes the registration, as the real one does.
    static func fakeClaude() throws -> URL {
        let bin = CLIHome.root.appendingPathComponent("bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$HOME/claude-calls.log"
            printf '{"mcpServers":{"cadence":{"type":"stdio","command":"%s","args":["mcp"]}}}' "$9" > "$HOME/.claude.json"

            """
        let file = bin.appendingPathComponent("claude")
        _ = FileManager.default.createFile(atPath: file.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        return bin
    }

    static func environment(claude: URL?) -> [String: String] {
        ["PATH": (claude.map { $0.path + ":" } ?? "") + "/usr/bin:/bin"]
    }

    static func write(_ text: String, to url: URL, mode: Int = 0o644) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
    }

    static func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Everything under a folder with its bytes and modification time.
    static func snapshot(_ folder: URL) -> [String: String] {
        var out: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return out }
        for case let relative as String in walker {
            let attributes = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(relative).path)) ?? [:]
            let bytes = (try? Data(contentsOf: folder.appendingPathComponent(relative))).map { Array($0) } ?? []
            out[relative] = "\(attributes[.modificationDate] ?? "") \(bytes)"
        }
        return out
    }

    // MARK: --print

    @Test func printChangesNothingAndCreatesNothing() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        let claude = try Self.fakeClaude()
        let result = try cli.run(["setup", "claude-code", "--print"], environment: Self.environment(claude: claude))
        #expect(result.status == 0)
        #expect(result.stdout.hasPrefix("Nothing was changed. Run cadence setup claude-code --apply to make these changes."))
        #expect(result.stdout.contains("hooks: add SessionStart, SessionEnd, Stop and TaskCompleted to ~/.claude/settings.json"))
        #expect(result.stdout.contains(#"claude mcp add --transport stdio --scope user cadence -- "$HOME/.local/bin/cadence" mcp"#))
        #expect(result.stdout.contains("skill: copy the cadence skill to ~/.claude/skills/cadence/SKILL.md"))
        // Not even the folders exist afterwards, and the pretend claude never ran.
        #expect(!FileManager.default.fileExists(atPath: cli.userHome.path))
        #expect(!FileManager.default.fileExists(atPath: cli.home.path))
    }

    @Test func printLeavesAnExistingHomeByteForByteAlone() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        let claude = try Self.fakeClaude()
        try Self.write(#"{"model": "opus", "hooks": {"Stop": []}}"#, to: cli.userHome.appendingPathComponent(Self.settingsPath), mode: 0o600)
        try Self.write("my skill\n", to: cli.userHome.appendingPathComponent(".claude/skills/cadence/SKILL.md"))
        try Self.write("{}", to: cli.userHome.appendingPathComponent(".claude.json"))
        let before = Self.snapshot(cli.userHome)
        let result = try cli.run(["setup", "claude-code", "--print"], environment: Self.environment(claude: claude))
        #expect(result.status == 0)
        #expect(result.stdout.contains("The current file is saved first as ~/.claude/settings.json.cadence-backup, mode 0600."))
        #expect(result.stdout.contains("skill: replace ~/.claude/skills/cadence/SKILL.md"))
        #expect(Self.snapshot(cli.userHome) == before)
    }

    @Test func printAsJSON() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        let claude = try Self.fakeClaude()
        let result = try cli.run(["setup", "claude-code", "--print", "--json"], environment: Self.environment(claude: claude))
        #expect(result.status == 0)
        let json = try result.json()
        #expect(json["mode"]?.stringValue == "print")
        #expect(json["changed"]?.boolValue == false)
        #expect(json["hooks"]?["add"]?.arrayValue?.count == 4)
        #expect(json["mcp"]?["action"]?.stringValue == "register")
        #expect(json["mcp"]?["command"]?.arrayValue?.first?.stringValue == claude.appendingPathComponent("claude").path)
        #expect(json["skill"]?["action"]?.stringValue == "create")
    }

    @Test func oneOfPrintAndApplyIsRequired() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        for arguments in [["setup", "claude-code"], ["setup", "claude-code", "--print", "--apply"]] {
            let result = try cli.run(arguments)
            #expect(result.status == 1, "\(arguments)")
            #expect(result.stderr.contains("cadence: choose one of --print and --apply"))
        }
        #expect(!FileManager.default.fileExists(atPath: cli.userHome.path))
    }

    // MARK: --apply

    @Test func applyThenDoctorThenApplyAgain() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        let claude = try Self.fakeClaude()
        let environment = Self.environment(claude: claude)
        let binary = cli.userHome.appendingPathComponent(".local/bin/cadence")
        try Self.write("#!/bin/sh\n", to: binary, mode: 0o755)

        let first = try cli.run(["setup", "claude-code", "--apply"], environment: environment)
        #expect(first.status == 0, "\(first.stderr)")
        #expect(first.stdout.contains("hooks: added SessionStart, SessionEnd, Stop and TaskCompleted to ~/.claude/settings.json"))
        #expect(first.stdout.contains("mcp server: registered cadence with Claude Code for your user"))
        #expect(first.stdout.contains("skill: copied the cadence skill to ~/.claude/skills/cadence/SKILL.md"))
        #expect(first.stdout.contains("Start a new Claude Code session"))

        let settings = cli.userHome.appendingPathComponent(Self.settingsPath)
        let installed = try Data(contentsOf: settings)
        #expect(try OrderedJSON.parse(Array(installed)) == (try OrderedJSON.parse(Array(ClaudeCodeIntegration.hooksJSON.utf8))))
        #expect(try String(contentsOf: cli.userHome.appendingPathComponent(".claude/skills/cadence/SKILL.md"), encoding: .utf8) == ClaudeCodeIntegration.skillMarkdown)
        let calls = Self.lines(cli.userHome.appendingPathComponent("claude-calls.log"))
        #expect(calls == ["mcp add --transport stdio --scope user cadence -- \(binary.path) mcp"])

        // doctor now finds all three
        let doctor = try cli.run(["doctor"], environment: environment)
        #expect(doctor.status == 0)
        #expect(doctor.stdout.contains("ok    mcp server: registered for your user in ~/.claude.json and runs ~/.local/bin/cadence mcp"))
        #expect(doctor.stdout.contains("ok    hooks: all four events run cadence in ~/.claude/settings.json"))
        #expect(doctor.stdout.contains("ok    skill: installed at ~/.claude/skills/cadence/SKILL.md"))

        // a second apply changes nothing and does not run claude again
        let before = Self.snapshot(cli.userHome)
        let second = try cli.run(["setup", "claude-code", "--apply"], environment: environment)
        #expect(second.status == 0)
        #expect(second.stdout.hasPrefix("Nothing to change."))
        #expect(Self.snapshot(cli.userHome) == before)
        #expect(Self.lines(cli.userHome.appendingPathComponent("claude-calls.log")).count == 1)
    }

    @Test func applyKeepsTheUsersSettingsAndSavesABackup() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        let original = """
            {
              "model": "opus",
              "hooks": {
                "Stop": [{ "hooks": [{ "type": "command", "command": "/usr/local/bin/notify" }] }]
              }
            }
            """
        let settings = cli.userHome.appendingPathComponent(Self.settingsPath)
        try Self.write(original, to: settings, mode: 0o600)
        let result = try cli.run(["setup", "claude-code", "--apply", "--json"], environment: Self.environment(claude: nil))
        #expect(result.status == 0, "\(result.stderr)")
        let json = try result.json()
        #expect(json["mode"]?.stringValue == "apply")
        #expect(json["changed"]?.boolValue == true)
        #expect(json["mcp"]?["outcome"]?.stringValue == "skipped")

        let backup = cli.userHome.appendingPathComponent(".claude/settings.json.cadence-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        let mode = (try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)

        let merged = try OrderedJSON.parse(Array(try Data(contentsOf: settings)))
        #expect(merged["model"] == .string("opus"))
        let stop = try #require(merged["hooks"]?["Stop"]?.arrayValue)
        #expect(stop.count == 2)
        #expect(stop[0]["hooks"]?.arrayValue?.first?["command"]?.stringValue == "/usr/local/bin/notify")
        #expect(merged["hooks"]?["SessionStart"]?.arrayValue?.count == 1)
    }

    @Test func applyWithoutClaudeSkipsTheRegistrationAndSaysSo() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        let result = try cli.run(["setup", "claude-code", "--apply"], environment: Self.environment(claude: nil))
        #expect(result.status == 0)
        #expect(result.stdout.contains("mcp server: skipped, claude is not on your PATH"))
        #expect(FileManager.default.fileExists(atPath: cli.userHome.appendingPathComponent(Self.settingsPath).path))
        #expect(result.stdout.contains("note: ~/.local/bin/cadence is not installed yet"))
    }

    @Test func applyRefusesASettingsFileItCannotMergeInto() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        let settings = cli.userHome.appendingPathComponent(Self.settingsPath)
        try Self.write("{ not json", to: settings)
        let result = try cli.run(["setup", "claude-code", "--apply"], environment: Self.environment(claude: nil))
        #expect(result.status == 2)
        #expect(result.stderr.hasPrefix("cadence: ~/.claude/settings.json is not valid JSON"))
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: cli.userHome.appendingPathComponent(".claude/settings.json.cadence-backup").path))
    }

    // MARK: doctor

    @Test func doctorOnAFreshHomeWarnsAboutTheIntegrationAndStillPasses() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        let result = try cli.run(["doctor"], environment: Self.environment(claude: nil))
        #expect(result.status == 0)
        #expect(result.stdout.contains("warn  mcp server: not registered; run cadence setup claude-code --apply"))
        #expect(result.stdout.contains("warn  hooks: ~/.claude/settings.json does not exist; run cadence setup claude-code --apply"))
        #expect(result.stdout.contains("warn  skill: not installed; run cadence setup claude-code --apply"))
        #expect(result.stdout.contains("ok    spool: no hook lines are waiting"))
        #expect(result.stdout.contains("warn  transcript retention: cleanupPeriodDays is not set"))
        #if os(Linux)
            #expect(result.stdout.contains("ok    agent: not applicable on this system"))
        #endif
        let json = try cli.json(["doctor"])
        #expect(json["ok"]?.boolValue == true)
        let names = json["checks"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        for name in ["mcp server", "hooks", "skill", "spool", "transcript retention", "agent"] {
            #expect(names.contains(name), "\(name)")
        }
    }

    @Test func doctorReadsCleanupPeriodDaysFromTheHomeItIsGiven() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        let settings = cli.userHome.appendingPathComponent(Self.settingsPath)
        try Self.write(#"{"cleanupPeriodDays": 400}"#, to: settings, mode: 0o600)
        #expect(try cli.run(["doctor"]).stdout.contains("ok    transcript retention: cleanupPeriodDays is 400 in ~/.claude/settings.json"))
        try Self.write(#"{"cleanupPeriodDays": 30}"#, to: settings, mode: 0o600)
        let low = try cli.run(["doctor"])
        #expect(low.status == 0)
        #expect(low.stdout.contains("warn  transcript retention: cleanupPeriodDays is 30, below 400"))
        try Self.write("{ nope", to: settings, mode: 0o600)
        #expect(try cli.run(["doctor"]).stdout.contains("warn  transcript retention: unknown, ~/.claude/settings.json is not valid JSON"))
    }

    @Test func doctorWarnsOfASpoolBacklogPastADay() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        try cli.run(["rebuild"])  // creates the Cadence folders with their modes
        let then = Date().addingTimeInterval(-3 * 86400)
        let stamp = Timestamp.utc(then)
        let line = #"{"at":"\#(stamp)","event":"stop","session_id":"s-1","v":1}"# + "\n"
        try Self.write(line, to: cli.home.appendingPathComponent("spool/hooks-\(stamp.prefix(10)).ndjson"), mode: 0o600)
        let result = try cli.run(["doctor"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("warn  spool: 1 hook line in 1 file is waiting, the oldest is 3 days old; run cadence spool drain"))
        // Draining clears it.
        #expect(try cli.run(["spool", "drain"]).status == 0)
        #expect(try cli.run(["doctor"]).stdout.contains("ok    spool: no hook lines are waiting"))
    }

    @Test func doctorUsesTheHomeFromTheEnvironmentNotTheRealOne() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        // The harness sets HOME; a different HOME gives a different answer.
        let other = CLIHome()
        defer { other.remove() }
        try Self.write(#"{"cleanupPeriodDays": 999}"#, to: other.userHome.appendingPathComponent(Self.settingsPath), mode: 0o600)
        let result = try cli.run(["doctor"], environment: ["HOME": other.userHome.path])
        #expect(result.stdout.contains("ok    transcript retention: cleanupPeriodDays is 999"))
    }
}
