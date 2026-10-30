import Foundation
import Testing

@testable import CadenceCore

@Suite struct ClaudeCodeSetupTests {
    static let userSettings = """
        {
          "model": "opus",
          "ratio": 1.50,
          "env": { "KEEP": "1" },
          "permissions": { "allow": ["Bash(git status)"] },
          "hooks": {
            "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "/usr/local/bin/guard" }] }],
            "Stop": [{ "hooks": [{ "type": "command", "command": "/usr/local/bin/notify stop" }] }]
          }
        }
        """

    static func parse(_ text: String?) throws -> OrderedJSON {
        try OrderedJSON.parse(Array((text ?? "").utf8))
    }

    // MARK: print changes nothing

    @Test func planOnAnEmptyHomeTouchesNothingAndRunsNothing() throws {
        let home = ClaudeHome()
        let bin = home.installFakeClaude()
        let before = home.snapshot()
        let plan = try home.setup(path: bin).plan()
        #expect(home.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: home.paths.claudeFolder.path))
        #expect(home.runner.requests.isEmpty)
        #expect(plan.hooks.action == .create)
        #expect(plan.hooks.added == ["SessionStart", "SessionEnd", "Stop", "TaskCompleted"])
        #expect(plan.hooks.backup == nil)
        #expect(plan.mcp.action == .register)
        #expect(plan.mcp.claude == bin.appendingPathComponent("claude").path)
        #expect(plan.skill.action == .create)
        #expect(plan.changesAnything)
    }

    @Test func planOnAnExistingSettingsFileLeavesItAlone() throws {
        let home = ClaudeHome()
        home.writeSettings(Self.userSettings)
        let before = home.snapshot()
        let plan = try home.setup(path: nil).plan()
        #expect(home.snapshot() == before)
        #expect(plan.hooks.action == .merge)
        // The user's own Stop hook does not run cadence, so all four are added.
        #expect(plan.hooks.added == ["SessionStart", "SessionEnd", "Stop", "TaskCompleted"])
        #expect(plan.hooks.present.isEmpty)
        #expect(plan.hooks.backup == home.paths.settingsBackup)
    }

    @Test func theReportNamesWhatWouldChange() throws {
        let home = ClaudeHome()
        let bin = home.installFakeClaude()
        let text = try home.setup(path: bin).plan().human
        #expect(text.hasPrefix("Nothing was changed. Run cadence setup claude-code --apply to make these changes."))
        #expect(text.contains("hooks: add SessionStart, SessionEnd, Stop and TaskCompleted to ~/.claude/settings.json"))
        #expect(text.contains(#"claude mcp add --transport stdio --scope user cadence -- "$HOME/.local/bin/cadence" mcp"#))
        #expect(text.contains("skill: copy the cadence skill to ~/.claude/skills/cadence/SKILL.md"))
        #expect(text.contains(#""command": "\"$HOME/.local/bin/cadence\" hook session-start""#))
        #expect(!text.contains("\u{2013}") && !text.contains("\u{2014}"))
    }

    @Test func theReportWarnsWhenTheBinaryIsNotInstalledYet() throws {
        let home = ClaudeHome()
        let text = try home.setup(path: nil).plan().human
        #expect(text.contains("~/.local/bin/cadence is not installed yet"))
        home.installBinary()
        #expect(!(try home.setup(path: nil).plan().human).contains("is not installed yet"))
    }

    // MARK: apply on an empty home

    @Test func applyOnAnEmptyHomeCreatesTheThreeThings() throws {
        let home = ClaudeHome()
        let bin = home.installFakeClaude()
        home.runner.onRun { [paths = home.paths] _ in
            // The pretend claude records the registration, as the real one does.
            try? Data(#"{"mcpServers":{"cadence":{"type":"stdio","command":"\#(paths.cadenceBinary.path)","args":["mcp"]}}}"#.utf8)
                .write(to: paths.userConfig)
        }
        let result = try home.setup(path: bin).apply()
        #expect(result.mcp == .registered)

        // hooks: exactly the embedded block, a private file, no backup because there was nothing to save
        let settings = try Self.parse(home.read(home.paths.settings))
        let block = try Self.parse(ClaudeCodeIntegration.hooksJSON)
        #expect(settings == block)
        #expect(home.mode(home.paths.settings) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: home.paths.settingsBackup.path))
        #expect(home.read(home.paths.settings)?.hasSuffix("}\n") == true)

        // skill: the embedded text
        #expect(home.read(home.paths.skillFile) == ClaudeCodeIntegration.skillMarkdown)

        // mcp: one argv-only call with the expanded binary path and a minimal environment
        let request = try #require(home.runner.requests.first)
        #expect(home.runner.requests.count == 1)
        #expect(request.executable == bin.appendingPathComponent("claude").path)
        #expect(
            request.arguments == [
                "mcp", "add", "--transport", "stdio", "--scope", "user", "cadence", "--", home.paths.cadenceBinary.path, "mcp",
            ])
        #expect(request.environment["HOME"] == home.home.path)
        #expect(request.environment["PATH"]?.hasPrefix(bin.path) == true)
        #expect(request.environment["SECRET_TOKEN"] == nil)
        #expect(request.stdin == nil)
        #expect(request.workingDirectory == home.home)
    }

    @Test func aSecondApplyChangesNothingAtAll() throws {
        let home = ClaudeHome()
        let bin = home.installFakeClaude()
        home.writeSettings(Self.userSettings)
        home.runner.onRun { [paths = home.paths] _ in
            try? Data(#"{"mcpServers":{"cadence":{"type":"stdio","command":"\#(paths.cadenceBinary.path)","args":["mcp"]}}}"#.utf8)
                .write(to: paths.userConfig)
        }
        _ = try home.setup(path: bin).apply()
        let original = Self.userSettings
        #expect(home.read(home.paths.settingsBackup) == original)
        let before = home.snapshot()

        let plan = try home.setup(path: bin).plan()
        #expect(plan.hooks.action == .none)
        #expect(plan.mcp.action == .alreadyRegistered)
        #expect(plan.skill.action == .none)
        #expect(!plan.changesAnything)

        let second = try home.setup(path: bin).apply()
        #expect(second.mcp == .unchanged)
        #expect(home.snapshot() == before)
        #expect(home.runner.requests.count == 1)
        // The backup still holds the file as it was before cadence first touched it.
        #expect(home.read(home.paths.settingsBackup) == original)
    }

    // MARK: the hooks merge

    @Test func mergeKeepsOtherKeysHooksOrderAndNumberText() throws {
        let home = ClaudeHome()
        home.writeSettings(Self.userSettings)
        _ = try home.setup(path: nil).apply()
        let merged = try Self.parse(home.read(home.paths.settings))
        #expect(merged.members?.map(\.key) == ["model", "ratio", "env", "permissions", "hooks"])
        #expect(merged["model"] == .string("opus"))
        #expect(merged["ratio"] == .number("1.50"))
        #expect(merged["env"]?["KEEP"] == .string("1"))
        let hooks = try #require(merged["hooks"])
        #expect(hooks.members?.map(\.key) == ["PreToolUse", "Stop", "SessionStart", "SessionEnd", "TaskCompleted"])
        let original = try Self.parse(Self.userSettings)
        #expect(hooks["PreToolUse"] == original["hooks"]?["PreToolUse"])
        // The user's own Stop hook stays first, ours follows it.
        let stop = try #require(hooks["Stop"]?.arrayValue)
        #expect(stop.count == 2)
        #expect(stop[0] == original["hooks"]?["Stop"]?.arrayValue?[0])
        #expect(stop[1]["hooks"]?.arrayValue?.first?["command"]?.stringValue == #""$HOME/.local/bin/cadence" hook stop"#)
        #expect(stop[1]["hooks"]?.arrayValue?.first?["async"] == .bool(true))
        #expect(merged.serialized().contains(#""ratio": 1.50"#))
        #expect(home.mode(home.paths.settingsBackup) == 0o600)
        #expect(home.read(home.paths.settingsBackup) == Self.userSettings)
    }

    @Test func aCadenceHookWrittenAnotherWayIsNotDuplicated() throws {
        let home = ClaudeHome()
        home.writeSettings(
            """
            {"hooks": {
              "SessionStart": [{"hooks": [{"type": "command", "command": "/opt/tools/cadence hook session-start", "timeout": 9}]}],
              "SessionEnd": [{"matcher": "", "hooks": [{"type": "command", "command": "'/home/x y/.local/bin/cadence' hook session-end"}]}],
              "Stop": [{"hooks": [{"type": "command", "command": "cadence hook session-start"}]}]
            }}
            """)
        let plan = try home.setup(path: nil).plan()
        // A hook for the wrong event does not count for Stop.
        #expect(plan.hooks.present == ["SessionStart", "SessionEnd"])
        #expect(plan.hooks.added == ["Stop", "TaskCompleted"])
        _ = try home.setup(path: nil).apply()
        let merged = try Self.parse(home.read(home.paths.settings))
        #expect(merged["hooks"]?["SessionStart"]?.arrayValue?.count == 1)
        #expect(merged["hooks"]?["SessionEnd"]?.arrayValue?.count == 1)
        #expect(merged["hooks"]?["Stop"]?.arrayValue?.count == 2)
    }

    @Test func aSettingsFileWithoutHooksGetsAHooksObjectAtTheEnd() throws {
        let home = ClaudeHome()
        home.writeSettings(#"{"cleanupPeriodDays": 400, "env": {}}"#)
        _ = try home.setup(path: nil).apply()
        let merged = try Self.parse(home.read(home.paths.settings))
        #expect(merged.members?.map(\.key) == ["cleanupPeriodDays", "env", "hooks"])
        #expect(merged["cleanupPeriodDays"] == .number("400"))
    }

    @Test func anEmptyObjectIsFine() throws {
        let home = ClaudeHome()
        home.writeSettings("{}")
        let plan = try home.setup(path: nil).plan()
        #expect(plan.hooks.action == .merge)
        _ = try home.setup(path: nil).apply()
        #expect(try Self.parse(home.read(home.paths.settings)) == (try Self.parse(ClaudeCodeIntegration.hooksJSON)))
    }

    @Test(arguments: [
        "{ not json", "[]", #"{"hooks": []}"#, #"{"hooks": {"Stop": {"hooks": []}}}"#, #"{"hooks": {"Stop": "x"}}"#, "",
    ])
    func aSettingsFileCadenceCannotMergeIntoIsLeftAloneAndExplained(_ text: String) throws {
        let home = ClaudeHome()
        let bin = home.installFakeClaude()
        home.writeSettings(text)
        let before = home.snapshot()
        do {
            _ = try home.setup(path: bin).apply()
            Issue.record("expected a refusal for \(text)")
        } catch {
            #expect(error.exitCode == 2)
            #expect(error.message.contains("~/.claude/settings.json"))
        }
        #expect(home.snapshot() == before)
        #expect(home.runner.requests.isEmpty)
    }

    @Test func aSymlinkedSettingsFileStaysASymlink() throws {
        let home = ClaudeHome()
        let dotfiles = TestStore.tempDirectory("dotfiles")
        let target = home.write(Self.userSettings, to: dotfiles.appendingPathComponent("settings.json"), mode: 0o644)
        try FileManager.default.createDirectory(at: home.paths.claudeFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.paths.settings, withDestinationURL: target)
        _ = try home.setup(path: nil).apply()
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: home.paths.settings.path)) == target.path)
        #expect(try Self.parse(home.read(target))["hooks"]?["SessionStart"] != nil)
        #expect(home.mode(target) == 0o644)
        #expect(home.read(home.paths.settingsBackup) == Self.userSettings)
    }

    @Test func theFileKeepsItsOwnMode() throws {
        let home = ClaudeHome()
        home.writeSettings("{}", mode: 0o640)
        _ = try home.setup(path: nil).apply()
        #expect(home.mode(home.paths.settings) == 0o640)
        #expect(home.mode(home.paths.settingsBackup) == 0o600)
    }

    @Test func aNewClaudeFolderIsPrivate() throws {
        let home = ClaudeHome()
        _ = try home.setup(path: nil).apply()
        #expect(home.mode(home.paths.claudeFolder) == 0o700)
    }

    // MARK: MCP registration

    @Test func aMatchingRegistrationIsLeftAlone() throws {
        let home = ClaudeHome()
        let bin = home.installFakeClaude()
        home.writeUserConfig()
        let plan = try home.setup(path: bin).plan()
        #expect(plan.mcp.action == .alreadyRegistered)
        let result = try home.setup(path: bin).apply()
        #expect(result.mcp == .unchanged)
        #expect(home.runner.requests.isEmpty)
    }

    @Test func aDifferentRegistrationIsReportedAndNotReplaced() throws {
        let home = ClaudeHome()
        let bin = home.installFakeClaude()
        home.writeUserConfig(command: "/opt/other/server", args: ["--stdio"])
        let plan = try home.setup(path: bin).plan()
        #expect(plan.mcp.action == .differs("/opt/other/server --stdio"))
        let result = try home.setup(path: bin).apply()
        #expect(result.mcp == .unchanged)
        #expect(result.human.contains("mcp server: left alone"))
        #expect(result.human.contains("claude mcp remove cadence --scope user"))
        #expect(home.runner.requests.isEmpty)
    }

    @Test func withoutClaudeOnPathTheStepIsSkippedAndTheRestIsDone() throws {
        let home = ClaudeHome()
        let result = try home.setup(path: nil).apply()
        #expect(result.mcp == .skipped("claude is not on your PATH"))
        #expect(home.runner.requests.isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.paths.settings.path))
        #expect(FileManager.default.fileExists(atPath: home.paths.skillFile.path))
        #expect(result.human.contains("mcp server: skipped, claude is not on your PATH"))
        #expect(result.human.contains(#"claude mcp add --transport stdio --scope user cadence -- "$HOME/.local/bin/cadence" mcp"#))
    }

    @Test func claudeLookupIgnoresRelativeEntriesAndFolders() throws {
        let home = ClaudeHome()
        let bin = TestStore.tempDirectory("bin")
        try FileManager.default.createDirectory(
            at: bin.appendingPathComponent("claude"), withIntermediateDirectories: true)
        let setup = ClaudeCodeSetup(
            userHome: home.home, environment: ["PATH": "relative/bin::\(bin.path)"], runner: home.runner)
        #expect(try setup.plan().mcp.action == .unavailable)
    }

    @Test func aFailingClaudeIsAnErrorAfterTheOtherStepsAreDone() throws {
        let home = ClaudeHome()
        let bin = home.installFakeClaude()
        home.runner.answer(with: .success(.exited(1, stderr: "something broke\nsecond line")))
        do {
            _ = try home.setup(path: bin).apply()
            Issue.record("expected a failure")
        } catch {
            #expect(error.exitCode == 1)
            #expect(error.message.contains("claude mcp add failed"))
            #expect(error.message.contains("something broke"))
        }
        #expect(FileManager.default.fileExists(atPath: home.paths.settings.path))
        #expect(FileManager.default.fileExists(atPath: home.paths.skillFile.path))
    }

    @Test func aClaudeThatTimesOutIsAnError() throws {
        let home = ClaudeHome()
        let bin = home.installFakeClaude()
        home.runner.answer(with: .success(.exited(0, timedOut: true)))
        #expect(throws: CadenceError.self) { try home.setup(path: bin).apply() }
    }

    @Test func aClaudeThatCannotStartIsAnError() throws {
        let home = ClaudeHome()
        let bin = home.installFakeClaude()
        home.runner.answer(with: .failure(.io("cannot run claude")))
        #expect(throws: CadenceError.self) { try home.setup(path: bin).apply() }
    }

    // MARK: the skill

    @Test func aDifferentSkillIsReplacedAfterABackup() throws {
        let home = ClaudeHome()
        home.write("my own notes\n", to: home.paths.skillFile)
        let plan = try home.setup(path: nil).plan()
        #expect(plan.skill.action == .replace)
        #expect(plan.skill.backup == home.paths.skillBackup)
        _ = try home.setup(path: nil).apply()
        #expect(home.read(home.paths.skillFile) == ClaudeCodeIntegration.skillMarkdown)
        #expect(home.read(home.paths.skillBackup) == "my own notes\n")
        #expect(home.mode(home.paths.skillBackup) == 0o600)
    }

    @Test func anIdenticalSkillIsLeftAlone() throws {
        let home = ClaudeHome()
        home.write(ClaudeCodeIntegration.skillMarkdown, to: home.paths.skillFile)
        #expect(try home.setup(path: nil).plan().skill.action == .none)
    }

    // MARK: json

    @Test func theJSONReportCarriesTheSameFacts() throws {
        let home = ClaudeHome()
        let bin = home.installFakeClaude()
        let json = try home.setup(path: bin).plan().json
        #expect(json["mode"]?.stringValue == "print")
        #expect(json["changed"] == .bool(false))
        #expect(json["hooks"]?["action"]?.stringValue == "create")
        #expect(json["hooks"]?["add"]?.arrayValue?.count == 4)
        #expect(json["hooks"]?["file"]?.stringValue == home.paths.settings.path)
        #expect(json["mcp"]?["action"]?.stringValue == "register")
        #expect(json["skill"]?["action"]?.stringValue == "create")
    }
}
