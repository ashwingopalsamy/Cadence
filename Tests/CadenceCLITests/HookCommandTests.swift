import Foundation
import Testing

@testable import CadenceCore

@Suite struct HookCommandTests {
    @Test func hookWritesOneLineAndExitsZeroWithAnUnusableDatabase() throws {
        let home = CLIHome()
        defer { home.remove() }
        try FileManager.default.createDirectory(atPath: home.database, withIntermediateDirectories: true)
        let input = #"{"session_id":"s-1","cwd":"/home/sample/acme-service","source":"startup","model":"model-a","prompt":"private"}"#
        let result = try home.run(["hook", "session-start"], stdin: input)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        let spool = home.home.appendingPathComponent("spool")
        let files = try FileManager.default.contentsOfDirectory(atPath: spool.path)
        #expect(files.count == 1)
        let text = try String(contentsOf: spool.appendingPathComponent(files[0]), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1)
        #expect(text.contains(#""project":"acme-service""#))
        #expect(!text.contains("private"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.database).isEmpty)
    }

    @Test func malformedInputExitsZeroWritesNothingAndPrintsNothing() throws {
        let home = CLIHome()
        defer { home.remove() }
        for event in ["session-end", "bogus"] {
            let result = try home.run(["hook", event], stdin: "not json")
            #expect(result.status == 0)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.split(separator: "\n").count <= 1)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: home.home.appendingPathComponent("spool").path)) ?? []
        #expect(files.isEmpty)
    }

    @Test func sessionStartPrintsThePlan() throws {
        let home = CLIHome()
        defer { home.remove() }
        _ = try home.run(["plan", "add", "Retry budget rollout"])
        let result = try home.run(["hook", "session-start"], stdin: #"{"session_id":"s-2","cwd":"/x/acme"}"#)
        #expect(result.status == 0)
        #expect(result.stdout.hasPrefix("Cadence plan for "))
        #expect(result.stdout.contains("0 of 1 done: Retry budget rollout"))
    }
}
