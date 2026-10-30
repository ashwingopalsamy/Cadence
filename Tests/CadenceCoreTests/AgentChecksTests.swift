import Foundation
import Testing

@testable import CadenceCore

/// The doctor checks for the Claude Code integration and the collector agent (docs/PLAN.md T2.20). Every test
/// runs against a throwaway home; `unknown` is reported when a file cannot be read, never a guess.
@Suite struct AgentChecksTests {
    /// 2026-09-21T14:13:20Z
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let allEvents = ["SessionStart", "SessionEnd", "Stop", "TaskCompleted"]

    struct Fixture {
        let claude = ClaudeHome()
        let roots = FileRoots(home: TestStore.tempDirectory("cadence-home"))
        let runner = RecordingRunner()

        func checks(platform: HostPlatform = .other, extra: [String: String] = [:]) -> [AgentChecks.Result] {
            AgentChecks(
                paths: claude.paths, roots: roots, clock: ManualClock(AgentChecksTests.now), environment: extra,
                runner: runner, platform: platform, uid: 501
            ).run()
        }

        func check(_ name: String, platform: HostPlatform = .other, extra: [String: String] = [:]) throws -> AgentChecks.Result {
            try #require(checks(platform: platform, extra: extra).first { $0.name == name }, "no check called \(name)")
        }

        func installHooks(events: [String] = AgentChecksTests.allEvents) throws {
            let block = try ClaudeCodeIntegration.hooksBlock().filter { events.contains($0.event) }
            let body = block.map { "\"\($0.event)\": \($0.groups.serialized())" }.joined(separator: ",")
            claude.writeSettings("{\"hooks\": {\(body)}}")
        }

        func spool(_ name: String, _ lines: [String], terminated: Bool = true) {
            let text = lines.joined(separator: "\n") + (terminated ? "\n" : "")
            claude.write(text, to: roots.spool.appendingPathComponent(name))
        }

        func drained(_ offsets: [String: Int]) {
            let files = offsets.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ",")
            claude.write("{\"files\": {\(files)}, \"v\": 1}", to: roots.state.appendingPathComponent("spool-drain.json"))
        }
    }

    static func line(_ at: String, session: String = "s-1", event: String = "stop") -> String {
        #"{"at":"\#(at)","event":"\#(event)","session_id":"\#(session)","v":1}"#
    }

    @Test func theChecksComeInTheDocumentedOrder() {
        let f = Fixture()
        #expect(f.checks().map(\.name) == ["mcp server", "hooks", "skill", "spool", "transcript retention", "agent"])
    }

    // MARK: mcp server

    @Test func mcpServerStatuses() throws {
        let f = Fixture()
        var result = try f.check("mcp server")
        #expect(result.level == .warn)
        #expect(result.detail == "not registered; run cadence setup claude-code --apply")

        f.claude.writeUserConfig()
        result = try f.check("mcp server")
        #expect(result.level == .warn)
        #expect(result.detail.contains("registered, but ~/.local/bin/cadence is missing or not executable"))

        f.claude.installBinary()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.claude.paths.cadenceBinary.path)
        result = try f.check("mcp server")
        #expect(result.level == .ok)
        #expect(result.detail == "registered for your user in ~/.claude.json and runs ~/.local/bin/cadence mcp")

        f.claude.writeUserConfig(command: "/opt/other/server", args: ["--stdio"])
        result = try f.check("mcp server")
        #expect(result.level == .warn)
        #expect(result.detail.hasPrefix(#"registered, but it runs "/opt/other/server --stdio" and not cadence mcp"#))

        f.claude.writeUserConfig(serverName: "someone-else")
        #expect(try f.check("mcp server").detail.hasPrefix("not registered"))
    }

    @Test func mcpServerIsUnknownWhenTheConfigCannotBeRead() throws {
        let f = Fixture()
        f.claude.write("{ nope", to: f.claude.paths.userConfig)
        let result = try f.check("mcp server")
        #expect(result.level == .warn)
        #expect(result.detail.hasPrefix("unknown, ~/.claude.json is not valid JSON"))
    }

    @Test func mcpServerReadsALargeConfigWithFractionsAndUnicode() throws {
        let f = Fixture()
        f.claude.installBinary()
        f.claude.write(
            #"{"projects": {"/x": {"lastCost": 0.0123, "history": ["café"], "big": 12345678901234567890}}, "mcpServers": {"cadence": {"command": "\#(f.claude.paths.cadenceBinary.path)", "args": ["mcp"]}}}"#,
            to: f.claude.paths.userConfig)
        #expect(try f.check("mcp server").level == .ok)
    }

    // MARK: hooks

    @Test func hooksStatuses() throws {
        let f = Fixture()
        var result = try f.check("hooks")
        #expect(result.level == .warn)
        #expect(result.detail == "~/.claude/settings.json does not exist; run cadence setup claude-code --apply")

        f.claude.writeSettings(#"{"model": "x"}"#)
        #expect(try f.check("hooks").detail == "no cadence hooks in ~/.claude/settings.json; run cadence setup claude-code --apply")

        try f.installHooks(events: ["SessionStart", "SessionEnd"])
        result = try f.check("hooks")
        #expect(result.level == .warn)
        #expect(
            result.detail
                == "Stop and TaskCompleted do not run cadence in ~/.claude/settings.json; run cadence setup claude-code --apply")

        try f.installHooks()
        result = try f.check("hooks")
        #expect(result.level == .warn)
        #expect(result.detail == "all four events are set, but ~/.local/bin/cadence is missing or not executable")

        f.claude.installBinary()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.claude.paths.cadenceBinary.path)
        result = try f.check("hooks")
        #expect(result.level == .ok)
        #expect(result.detail == "all four events run cadence in ~/.claude/settings.json")
    }

    @Test func hooksIsUnknownWhenSettingsCannotBeRead() throws {
        let f = Fixture()
        f.claude.writeSettings("{ nope")
        let result = try f.check("hooks")
        #expect(result.level == .warn)
        #expect(result.detail.hasPrefix("unknown, ~/.claude/settings.json is not valid JSON"))
    }

    @Test func hooksWrittenWithAnAbsolutePathAreRecognised() throws {
        let f = Fixture()
        let cadence = f.claude.paths.cadenceBinary
        f.claude.installBinary()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cadence.path)
        func hook(_ event: String) -> String {
            #"[{"hooks": [{"type": "command", "command": "\#(cadence.path) hook \#(event)"}]}]"#
        }
        f.claude.writeSettings(
            #"{"hooks": {"SessionStart": \#(hook("session-start")), "SessionEnd": \#(hook("session-end")), "Stop": \#(hook("stop")), "TaskCompleted": \#(hook("task-completed"))}}"#
        )
        #expect(try f.check("hooks").level == .ok)
    }

    // MARK: skill

    @Test func skillStatuses() throws {
        let f = Fixture()
        var result = try f.check("skill")
        #expect(result.level == .warn)
        #expect(result.detail == "not installed; run cadence setup claude-code --apply")

        f.claude.write("old text\n", to: f.claude.paths.skillFile)
        result = try f.check("skill")
        #expect(result.level == .warn)
        #expect(
            result.detail
                == "installed at ~/.claude/skills/cadence/SKILL.md, but it differs from the skill in this cadence; run cadence setup claude-code --apply to update it"
        )

        f.claude.write(ClaudeCodeIntegration.skillMarkdown, to: f.claude.paths.skillFile)
        result = try f.check("skill")
        #expect(result.level == .ok)
        #expect(result.detail == "installed at ~/.claude/skills/cadence/SKILL.md")
    }

    // MARK: spool

    @Test func anEmptyOrMissingSpoolIsFine() throws {
        let f = Fixture()
        #expect(try f.check("spool") == AgentChecks.Result(name: "spool", level: .ok, detail: "no hook lines are waiting"))
        f.claude.write("", to: f.roots.spool.appendingPathComponent("hooks-2026-09-21.ndjson"))
        #expect(try f.check("spool").detail == "no hook lines are waiting")
    }

    @Test func waitingLinesAreCountedWithTheAgeOfTheOldest() throws {
        let f = Fixture()
        f.spool(
            "hooks-2026-09-21.ndjson",
            [Self.line("2026-09-21T10:00:00.000Z"), Self.line("2026-09-21T11:00:00.000Z"), Self.line("2026-09-21T12:00:00.000Z")])
        let result = try f.check("spool")
        #expect(result.level == .ok)
        #expect(result.detail == "3 hook lines in 1 file are waiting, the oldest is 4 h old")
    }

    @Test func linesWaitingPastADayWarn() throws {
        let f = Fixture()
        f.spool("hooks-2026-09-20.ndjson", [Self.line("2026-09-20T10:00:00.000Z")])
        f.spool("hooks-2026-09-21.ndjson", [Self.line("2026-09-21T10:00:00.000Z")])
        let result = try f.check("spool")
        #expect(result.level == .warn)
        #expect(result.detail == "2 hook lines in 2 files are waiting, the oldest is 28 h old; run cadence spool drain")
    }

    @Test func exactlyADayOldWarnsAndJustUnderDoesNot() throws {
        let f = Fixture()
        // now is 14:13:20Z on the 21st
        f.spool("hooks-2026-09-20.ndjson", [Self.line("2026-09-20T14:13:21.000Z")])
        #expect(try f.check("spool").level == .ok)
        f.spool("hooks-2026-09-20.ndjson", [Self.line("2026-09-20T14:13:20.000Z")])
        #expect(try f.check("spool").level == .warn)
    }

    @Test func drainedLinesAreNotABacklog() throws {
        let f = Fixture()
        let lines = [Self.line("2026-09-10T10:00:00.000Z"), Self.line("2026-09-10T11:00:00.000Z")]
        f.spool("hooks-2026-09-10.ndjson", lines)
        let size = lines.joined(separator: "\n").utf8.count + 1
        f.drained(["hooks-2026-09-10.ndjson": size])
        #expect(try f.check("spool").detail == "no hook lines are waiting")
        // Only what comes after the saved offset waits.
        f.spool("hooks-2026-09-10.ndjson", lines + [Self.line("2026-09-10T12:00:00.000Z")])
        let result = try f.check("spool")
        #expect(result.detail.hasPrefix("1 hook line in 1 file is waiting"))
        #expect(result.level == .warn)
    }

    @Test func anUnfinishedLastLineIsNotCounted() throws {
        let f = Fixture()
        f.spool("hooks-2026-09-21.ndjson", [Self.line("2026-09-21T10:00:00.000Z"), #"{"at":"2026-09-2"#], terminated: false)
        #expect(try f.check("spool").detail.hasPrefix("1 hook line in 1 file is waiting"))
    }

    @Test func otherFilesInTheSpoolFolderAreIgnored() throws {
        let f = Fixture()
        f.claude.write("junk\n", to: f.roots.spool.appendingPathComponent("notes.txt"))
        f.claude.write("junk\n", to: f.roots.spool.appendingPathComponent("hooks-2026-09-21.ndjson.bak"))
        #expect(try f.check("spool").detail == "no hook lines are waiting")
    }

    @Test func aBrokenDrainStateIsUnknownNotAGuess() throws {
        let f = Fixture()
        f.spool("hooks-2026-09-21.ndjson", [Self.line("2026-09-21T10:00:00.000Z")])
        f.claude.write("{ nope", to: f.roots.state.appendingPathComponent("spool-drain.json"))
        let result = try f.check("spool")
        #expect(result.level == .warn)
        #expect(result.detail.hasPrefix("unknown, state/spool-drain.json cannot be read"))
    }

    @Test(arguments: [
        (0.0, "under a minute"), (59, "under a minute"), (60, "1 min"), (3599, "59 min"), (3600, "1 h"), (47 * 3600 + 3599, "47 h"),
        (48 * 3600, "2 days"), (10 * 86400, "10 days"),
    ] as [(Double, String)])
    func agesReadNaturally(seconds: Double, text: String) {
        #expect(SpoolBacklog.ageText(seconds) == text)
    }

    // MARK: transcript retention

    @Test func retentionStatuses() throws {
        let f = Fixture()
        var result = try f.check("transcript retention")
        #expect(result.level == .warn)
        #expect(
            result.detail
                == "cleanupPeriodDays is not set, so Claude Code's default of 30 days applies; set it to at least 400 in ~/.claude/settings.json"
        )

        f.claude.writeSettings(#"{"hooks": {}}"#)
        #expect(try f.check("transcript retention").detail.hasPrefix("cleanupPeriodDays is not set"))

        f.claude.writeSettings(#"{"cleanupPeriodDays": 30}"#)
        result = try f.check("transcript retention")
        #expect(result.level == .warn)
        #expect(
            result.detail
                == "cleanupPeriodDays is 30, below 400, so Claude Code deletes older transcripts before Cadence collects them; set it to at least 400 in ~/.claude/settings.json"
        )

        for value in ["400", "401", "1000", "400.0", "4e2"] {
            f.claude.writeSettings(#"{"cleanupPeriodDays": \#(value)}"#)
            result = try f.check("transcript retention")
            #expect(result.level == .ok, "\(value)")
        }
        f.claude.writeSettings(#"{"cleanupPeriodDays": 400}"#)
        #expect(try f.check("transcript retention").detail == "cleanupPeriodDays is 400 in ~/.claude/settings.json")

        f.claude.writeSettings(#"{"cleanupPeriodDays": 399.5}"#)
        #expect(try f.check("transcript retention").level == .warn)
    }

    @Test func retentionIsUnknownWhenTheValueCannotBeTrusted() throws {
        let f = Fixture()
        for text in [#"{"cleanupPeriodDays": "400"}"#, #"{"cleanupPeriodDays": null}"#, #"{"cleanupPeriodDays": [400]}"#, "{ nope"] {
            f.claude.writeSettings(text)
            let result = try f.check("transcript retention")
            #expect(result.level == .warn, "\(text)")
            #expect(result.detail.hasPrefix("unknown, "), "\(text)")
        }
    }

    @Test func anUnreadableSpoolFolderOrFileIsUnknownNotOk() throws {
        // A file where the folder should be cannot be listed. Running as root rules out permission bits in tests,
        // so a directory stands in for a spool file that cannot be read.
        let f = Fixture()
        f.claude.write("not a folder\n", to: f.roots.spool)
        var result = try f.check("spool")
        #expect(result.level == .warn)
        #expect(result.detail == "unknown, the spool folder cannot be read")

        let g = Fixture()
        g.spool("hooks-2026-09-21.ndjson", [Self.line("2026-09-21T10:00:00.000Z")])
        try FileManager.default.createDirectory(
            at: g.roots.spool.appendingPathComponent("hooks-2026-09-20.ndjson"), withIntermediateDirectories: true)
        result = try g.check("spool")
        #expect(result.level == .warn)
        #expect(result.detail == "unknown, 1 of 2 spool files cannot be read; 1 hook line in the others is waiting")

        // Only the one that cannot be read: nothing is claimed about the rest.
        let h = Fixture()
        try FileManager.default.createDirectory(
            at: h.roots.spool.appendingPathComponent("hooks-2026-09-20.ndjson"), withIntermediateDirectories: true)
        result = try h.check("spool")
        #expect(result.level == .warn)
        #expect(result.detail == "unknown, 1 of 1 spool file cannot be read")
        // A missing folder is just an empty spool.
        #expect(try Fixture().check("spool").level == .ok)
    }

    // MARK: links and CLAUDE_CONFIG_DIR

    @Test func aLinkThatLeadsNowhereIsUnknownNotMissing() throws {
        let f = Fixture()
        let missing = TestStore.tempDirectory("dotfiles").appendingPathComponent("gone.json")
        try ClaudeCodeSetupTests.link(f.claude.paths.settings, to: missing.path)
        try ClaudeCodeSetupTests.link(f.claude.paths.skillFile, to: missing.path)
        for name in ["hooks", "transcript retention"] {
            let result = try f.check(name)
            #expect(result.level == .warn, "\(name)")
            #expect(
                result.detail.hasPrefix("unknown, ~/.claude/settings.json is a symbolic link to \(missing.path) that does not lead to a file"),
                "\(result.detail)")
        }
        let skill = try f.check("skill")
        #expect(skill.level == .warn)
        #expect(
            skill.detail
                == "unknown, ~/.claude/skills/cadence/SKILL.md is a symbolic link to \(missing.path) that does not lead to a file")
        // A loop is named as one.
        let g = Fixture()
        try ClaudeCodeSetupTests.link(g.claude.paths.settings, to: g.claude.paths.settings.path)
        #expect(try g.check("hooks").detail == "unknown, ~/.claude/settings.json is a symbolic link that loops")
    }

    @Test func claudeConfigDirIsWhereDoctorLooks() throws {
        let claude = ClaudeHome()
        let config = TestStore.tempDirectory("claude-config")
        let roots = FileRoots(home: TestStore.tempDirectory("cadence-home"))
        let environment = ["CLAUDE_CONFIG_DIR": config.path]
        let paths = ClaudeCodePaths(userHome: claude.home, environment: environment)
        func run(_ name: String) throws -> AgentChecks.Result {
            let results = AgentChecks(
                paths: paths, roots: roots, clock: ManualClock(Self.now), environment: environment, runner: RecordingRunner(),
                platform: .other, uid: 501
            ).run()
            return try #require(results.first { $0.name == name })
        }
        // Files in ~/.claude do not count when the variable names another folder.
        claude.writeSettings(#"{"cleanupPeriodDays": 400}"#)
        claude.write(ClaudeCodeIntegration.skillMarkdown, to: claude.paths.skillFile)
        claude.writeUserConfig()
        #expect(try run("transcript retention").detail.hasPrefix("cleanupPeriodDays is not set"))
        #expect(try run("skill").detail == "not installed; run cadence setup claude-code --apply")
        #expect(try run("mcp server").detail == "not registered; run cadence setup claude-code --apply")
        #expect(try run("hooks").detail == "\(config.path)/settings.json does not exist; run cadence setup claude-code --apply")

        // The same files in the named folder are found, and the registration is read from its .claude.json.
        claude.write(#"{"cleanupPeriodDays": 500}"#, to: config.appendingPathComponent("settings.json"))
        claude.write(ClaudeCodeIntegration.skillMarkdown, to: config.appendingPathComponent("skills/cadence/SKILL.md"))
        claude.write(
            #"{"mcpServers": {"cadence": {"type": "stdio", "command": "\#(paths.cadenceBinary.path)", "args": ["mcp"]}}}"#,
            to: config.appendingPathComponent(".claude.json"))
        #expect(try run("transcript retention").detail == "cleanupPeriodDays is 500 in \(config.path)/settings.json")
        #expect(try run("skill").detail == "installed at \(config.path)/skills/cadence/SKILL.md")
        let server = try run("mcp server")
        #expect(server.detail.hasPrefix("registered, but ~/.local/bin/cadence is missing or not executable"))
    }

    // MARK: collector agent

    @Test func offMacOSTheAgentIsNotApplicable() throws {
        let f = Fixture()
        let result = try f.check("agent", platform: .other)
        #expect(result == AgentChecks.Result(name: "agent", level: .ok, detail: "not applicable on this system"))
        #expect(f.runner.requests.isEmpty)
    }

    @Test func aLoadedAgentIsOk() throws {
        let f = Fixture()
        f.runner.answer(with: .success(.exited(0, stdout: "in.ashwingopalsamy.cadence.agent = {\n\tstate = not running\n\tlast exit code = 0\n}\n")))
        let result = try f.check("agent", platform: .macOS)
        #expect(result.level == .ok)
        #expect(result.detail == "loaded in launchd as in.ashwingopalsamy.cadence.agent")
        let request = try #require(f.runner.requests.first)
        #expect(request.executable == "/bin/launchctl")
        #expect(request.arguments == ["print", "gui/501/in.ashwingopalsamy.cadence.agent"])
    }

    @Test func aLoadedAgentWhoseLastRunFailedWarns() throws {
        let f = Fixture()
        f.runner.answer(with: .success(.exited(0, stdout: "\tlast exit code = 78\n")))
        let result = try f.check("agent", platform: .macOS)
        #expect(result.level == .warn)
        #expect(result.detail == "loaded, but its last run exited with 78; see the newest file in logs/")
    }

    @Test func aLoadedAgentThatNeverRanIsOk() throws {
        let f = Fixture()
        f.runner.answer(with: .success(.exited(0, stdout: "\tlast exit code = (never exited)\n")))
        #expect(try f.check("agent", platform: .macOS).level == .ok)
    }

    @Test func anAgentThatIsNotLoadedWarns() throws {
        let f = Fixture()
        f.runner.answer(with: .success(.exited(113, stderr: "Could not find service")))
        var result = try f.check("agent", platform: .macOS)
        #expect(result.level == .warn)
        #expect(
            result.detail
                == "not loaded; Cadence.app registers it at first launch, and until then collectors run only when you run cadence collect run"
        )
        let plist = f.claude.home.appendingPathComponent("Library/LaunchAgents/in.ashwingopalsamy.cadence.agent.plist")
        f.claude.write("<plist/>", to: plist)
        result = try f.check("agent", platform: .macOS)
        #expect(result.level == .warn)
        #expect(result.detail == "~/Library/LaunchAgents/in.ashwingopalsamy.cadence.agent.plist exists but launchd has not loaded it")
    }

    @Test func anAgentWeCannotAskAboutIsUnknown() throws {
        let f = Fixture()
        f.runner.answer(with: .failure(.io("cannot run /bin/launchctl")))
        let result = try f.check("agent", platform: .macOS)
        #expect(result.level == .warn)
        #expect(result.detail == "unknown, launchctl could not be run")
    }

    @Test func theAgentLabelCanBeOverriddenForAnotherBundlePrefix() throws {
        let f = Fixture()
        f.runner.answer(with: .success(.exited(0)))
        _ = try f.check("agent", platform: .macOS, extra: ["CADENCE_AGENT_LABEL": "com.example.cadence.agent"])
        #expect(f.runner.requests.first?.arguments == ["print", "gui/501/com.example.cadence.agent"])
        f.runner.answer(with: .success(.exited(0)))
        _ = try f.check("agent", platform: .macOS, extra: ["CADENCE_AGENT_LABEL": "bad label/../x"])
        #expect(f.runner.requests.last?.arguments == ["print", "gui/501/in.ashwingopalsamy.cadence.agent"])
    }

    @Test func detailsHaveNoDashes() {
        let f = Fixture()
        for result in f.checks(platform: .other) {
            #expect(!result.detail.contains("\u{2013}") && !result.detail.contains("\u{2014}"), "\(result.name)")
        }
    }
}
