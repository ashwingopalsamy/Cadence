import Foundation
import Testing

@testable import CadenceCore

@Suite struct SpoolDrainCommandTests {
    @Test func hookThenDrainRecordsTheSessionOnceAndAReplayIsQuiet() throws {
        let home = CLIHome()
        defer { home.remove() }
        _ = try home.run(["hook", "session-start"], stdin: #"{"session_id":"s-9","cwd":"/x/acme","model":"model-a"}"#)
        _ = try home.run(["hook", "session-end"], stdin: #"{"session_id":"s-9","reason":"clear"}"#)
        let first = try home.json(["spool", "drain"])
        #expect(first["events_written"]?.intValue == 1)
        let second = try home.json(["spool", "drain"])
        #expect(second["events_written"]?.intValue == 0)
        let human = try home.run(["spool", "drain"])
        #expect(human.status == 0)
        #expect(human.stdout.hasPrefix("Spool drained: 0 session events written"))
    }
}
