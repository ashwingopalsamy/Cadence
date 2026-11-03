import Foundation
import Testing

@testable import CadenceCore

/// The optional stand-up line of docs/SPEC.md section 11.2: off by default, "AI: 4 sessions · 2 of 3 merges AI-assisted".
@Suite struct StandupAILineTests {
    typealias G = GenAIMetricsTests
    static let zoneID = "Asia/Kolkata"

    /// A store whose clock reads 18:00 on Thu 29 Oct, with PRs and sessions on the 25th, 28th and 29th.
    static func store() throws -> (SQLiteStore, ManualClock) {
        let zone = TimeZone(identifier: zoneID)!
        let clock = ManualClock(Timestamp.resolve(LocalDate("2026-10-29")!, hour: 18, minute: 0, in: zone))
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        try store.ensureGenesis(profile: ["timezone": .string(zoneID)])
        try store.append([
            // The 29th: three sessions; PRs marked, marked, unmarked and with no recorded marker.
            G.merged("M1", day: "2026-10-29", ai: true), G.merged("M2", day: "2026-10-29", ai: true),
            G.merged("M3", day: "2026-10-29", ai: false), G.merged("M4", day: "2026-10-29", ai: nil),
            G.session("S1", day: "2026-10-29", start: "10:00", end: "10:30"), G.session("S2", day: "2026-10-29", start: "11:00"),
            G.session("S3", day: "2026-10-29", start: "12:00"),
            // The 28th: a session and one PR whose marker was never recorded.
            G.session("S4", day: "2026-10-28", start: "10:00"), G.merged("M5", day: "2026-10-28", ai: nil),
            // The 25th: one PR, not marked, and no session.
            G.merged("M6", day: "2026-10-25", ai: false),
            // The 27th: an entry that is not a PR and no session.
            G.create(G.entry("N1", day: "2026-10-27")),
        ])
        return (store, clock)
    }

    static func journal(_ store: SQLiteStore, _ clock: ManualClock, line: Bool) throws -> Journal {
        var config = Config.defaults(timezone: zoneID)
        config.genai.standupLine = line
        return try Journal(store: store, config: config, clock: clock, ids: CountingIDs())
    }

    static let titles = "\u{2022} Entry M1\n\u{2022} Entry M2\n\u{2022} Entry M3\n\u{2022} Entry M4"

    @Test func theLineIsOffByDefault() throws {
        let (store, clock) = try Self.store()
        #expect(Config.defaults(timezone: Self.zoneID).genai.standupLine == false)
        let journal = try Journal(store: store, config: Config.defaults(timezone: Self.zoneID), clock: clock, ids: CountingIDs())
        let text = try journal.standupText(LocalDate("2026-10-29")!)
        let expected = "*Thu 29 Oct*\nDone\n\(Self.titles)\nPRs merged 4 \u{00B7} Claude Code 3 sessions\nNext\n\u{2022} Nothing planned\nBlockers: none"
        #expect(text == expected)
        #expect(!text.contains("AI:"))
    }

    @Test func whenOnTheLineFollowsTheCountsAndCountsOnlyPRsWithARecordedMarker() throws {
        let (store, clock) = try Self.store()
        let on = try Self.journal(store, clock, line: true)
        let text = try on.standupText(LocalDate("2026-10-29")!)
        let expected = "*Thu 29 Oct*\nDone\n\(Self.titles)\nPRs merged 4 \u{00B7} Claude Code 3 sessions\n"
            + "AI: 3 sessions \u{00B7} 2 of 3 merges AI-assisted\nNext\n\u{2022} Nothing planned\nBlockers: none"
        #expect(text == expected)
        // The signed text is the same with a witness code after it, and the code stays the last line.
        let signed = try on.standup(LocalDate("2026-10-29")!, actor: .cli)
        #expect(signed.text == expected + "\ncadence \(signed.code)")
        #expect(signed.text.components(separatedBy: "\n").last == "cadence \(signed.code)")
    }

    @Test func partsWithNoRecordAreLeftOut() throws {
        let (store, clock) = try Self.store()
        let on = try Self.journal(store, clock, line: true)
        func ai(_ day: String) throws -> String? {
            try on.standupText(LocalDate(day)!).components(separatedBy: "\n").first { $0.hasPrefix("AI:") }
        }
        // One session and a PR with no recorded marker: only the session is known.
        #expect(try ai("2026-10-28") == "AI: 1 session")
        // A PR without the marker and no session: a known 0 of 1, and no session part.
        #expect(try ai("2026-10-25") == "AI: 0 of 1 merge AI-assisted")
        // Nothing about AI on the 27th: no line at all, not "AI: 0 sessions".
        #expect(try ai("2026-10-27") == nil)
        let off = try Self.journal(store, clock, line: false)
        #expect(try off.standupText(LocalDate("2026-10-27")!) == on.standupText(LocalDate("2026-10-27")!))
    }

    @Test func theLineWritesNothing() throws {
        let (store, clock) = try Self.store()
        let on = try Self.journal(store, clock, line: true)
        let count = try store.eventCount()
        _ = try on.standupText(LocalDate("2026-10-29")!)
        #expect(try store.eventCount() == count)
    }
}
