import CadenceCore
import Foundation
import Testing

@Suite struct ClassifierRecordTests {
    let cli = CLIHome()

    func classifierEvents() throws -> [Event] {
        try cli.journal().store.events(subject: "config").filter { $0.type == "config.classifier" }
    }

    @Test func changingTheTicketRulesRecordsHashesOnce() throws {
        defer { cli.remove() }
        let pattern = "(?<key>[A-Z]{2,5}-(?<num>[0-9]{3,6}))"
        try cli.run(["config", "set", "tickets.pattern", pattern])
        var events = try classifierEvents()
        #expect(events.count == 1)
        let hasher = SHA256Hasher()
        let recorded = try ConfigClassifier(json: events[0].data).patterns
        #expect(recorded.first == "sha256:" + hasher.sha256Hex(Array(pattern.utf8)))
        #expect(events[0].actor == .cli)
        #expect(!String(describing: events[0].data).contains("[A-Z]"))

        try cli.run(["config", "set", "tickets.pattern", pattern])
        try cli.run(["config", "set", "tickets.titleWindow", "20"])
        #expect(try classifierEvents().count == 1)

        try cli.run(["config", "set", "tickets.selfInitiated", "^9+$"])
        events = try classifierEvents()
        #expect(events.count == 2)
        #expect(try cli.run(["doctor"]).status == 0)
    }
}
