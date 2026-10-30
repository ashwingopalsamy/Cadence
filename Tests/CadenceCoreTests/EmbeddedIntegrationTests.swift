import Foundation
import Testing

@testable import CadenceCore

/// The hooks block and the skill ship inside the binary, so `cadence setup claude-code` works from `~/.local/bin`
/// with no repo around. These tests keep the copies equal to `integrations/claude-code`, byte for byte.
@Suite struct EmbeddedIntegrationTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CadenceCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // the repo root
        .appendingPathComponent("integrations/claude-code", isDirectory: true)

    static func bytes(_ relative: String) throws -> [UInt8] {
        Array(try Data(contentsOf: root.appendingPathComponent(relative)))
    }

    @Test func hooksBlockEqualsTheFileByteForByte() throws {
        #expect(Array(ClaudeCodeIntegration.hooksJSON.utf8) == (try Self.bytes("hooks.json")))
    }

    @Test func skillEqualsTheFileByteForByte() throws {
        #expect(Array(ClaudeCodeIntegration.skillMarkdown.utf8) == (try Self.bytes("skills/cadence/SKILL.md")))
    }

    @Test func theBlockRunsCadenceHookForExactlyTheFourEvents() throws {
        let block = try ClaudeCodeIntegration.hooksBlock()
        #expect(block.map(\.event) == ["SessionStart", "SessionEnd", "Stop", "TaskCompleted"])
        #expect(ClaudeCodeIntegration.hookEvents.map(\.claude) == block.map(\.event))
        #expect(ClaudeCodeIntegration.hookEvents.map(\.cli) == HookEventName.allCases)
        for entry in block {
            let cli = try #require(ClaudeCodeIntegration.hookEvents.first { $0.claude == entry.event }).cli
            let command = try #require(entry.groups.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue)
            #expect(command == "\"$HOME/.local/bin/cadence\" hook \(cli.rawValue)")
            #expect(HookCommandLine.parse(command)?.event == cli.rawValue)
        }
    }

    @Test func theSkillNamesItselfCadence() {
        #expect(ClaudeCodeIntegration.skillMarkdown.hasPrefix("---\nname: cadence\n"))
    }
}
