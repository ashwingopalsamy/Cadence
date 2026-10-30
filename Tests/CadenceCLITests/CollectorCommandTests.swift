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
}
