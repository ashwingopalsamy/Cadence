import CadenceCore
import Foundation
import Testing

/// `cadence doctor` tells the owner where the app's log is and what it holds (docs/SPEC.md section 13). It is one
/// static line: the CLI never reads the app's log, which holds timings and error codes and nothing the owner typed.
@Suite struct DoctorLogGuidanceTests {
    @Test func doctorSaysHowToReadTheAppLog() throws {
        let cli = CLIHome()
        defer { cli.remove() }
        let result = try cli.run(["doctor"])
        #expect(result.status == 0)
        #if os(macOS)
            let line =
                #"ok    app log: timings and error codes only, never titles or notes. Read it with: log show --predicate 'subsystem == "in.ashwingopalsamy.cadence"' --info --last 1h"#
            #expect(result.stdout.contains(line))
            let json = try cli.json(["doctor"])
            let checks = json["checks"]?.arrayValue ?? []
            let entry = checks.first { $0["name"]?.stringValue == "app log" }
            #expect(entry?["status"]?.stringValue == "ok")
        #else
            // No app, no app log.
            #expect(!result.stdout.contains("app log"))
        #endif
    }
}
