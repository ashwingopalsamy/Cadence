import Foundation
import Testing

@testable import CadenceCore

/// The new figures and the sentence in the proof summary (docs/SPEC.md sections 11 and 12.1).
@Suite struct ProofReviewSentenceTests {
    typealias T = ProofExportTests

    static func proof() throws -> (SQLiteStore, ManualClock, ProofFile) {
        let (store, clock) = try T.october()
        try GenAIMetricsTests.seed(store)
        return (store, clock, try ProofExporter.export(store, T.request(clock)))
    }

    static func summary(_ proof: ProofFile) -> [String: JSONValue] { proof.json.objectValue!["summary"]!.objectValue! }

    @Test func theSummaryCarriesTheFiguresAndTheSentenceWithDefinitions() throws {
        let (_, _, proof) = try Self.proof()
        let summary = Self.summary(proof)
        // Listed in range: the 28th's PR with no marker, and the 29th's three. G7 is excluded from the proof.
        #expect(summary["merged_prs"]?["value"] == 4)
        let assisted = try #require(summary["ai_assisted_merges"])
        #expect(assisted["value"] == 2 && assisted["of"] == 3 && assisted["percent"] == 67 && assisted["unrecorded"] == 1)
        #expect(summary["agent_entries"]?["value"] == 2)
        let sentence = try #require(summary["review_sentence"])
        #expect(sentence["text"]
            == "AI on 1 of 2 workdays. 67% of the 3 merged PRs with a recorded marker were AI-assisted. Your agent logged 2 entries you accepted.")
        for (name, metric) in summary { #expect(metric.objectValue?["definition"]?.stringValue?.isEmpty == false, "\(name)") }
        // Labelled as the spec says: computed by Cadence, not recomputed by the verifier.
        for name in ["ai_assisted_merges", "agent_entries", "review_sentence"] {
            #expect(summary[name]?["definition"]?.stringValue?.contains("computed by Cadence") == true, "\(name)")
        }
        #expect(summary["review_sentence"]?["definition"]?.stringValue?.contains("verifier") == true)
    }

    @Test func everyFigureInTheSentenceCanBeRecountedFromTheFile() throws {
        let (_, _, proof) = try Self.proof()
        let root = proof.json.objectValue!
        let items = root["days"]!.arrayValue!.flatMap { $0.objectValue!["items"]!.arrayValue! }.map { $0.objectValue! }
        let events = root["chain"]!.objectValue!["events"]!.arrayValue!.map { $0.objectValue! }
        var byHash: [String: [String: JSONValue]] = [:]
        for e in events { byHash[e["hash"]!.stringValue!] = e }
        // Agent entries: items with origin agent, which every item carries even when redacted.
        let agent = items.filter { $0["origin"] == "agent" }.count
        // AI-assisted merges: the marker in each merged PR's entry.created payload in the chain.
        let merged = items.filter { $0["kind"] == "pr.merged" && $0["origin"] == "collected" }
        let markers = merged.map { byHash[$0["ev"]!.stringValue!]?["data"]?["attrs"]?["ai_assisted"] }
        let summary = Self.summary(proof)
        #expect(Int64(agent) == summary["agent_entries"]?["value"]?.intValue)
        #expect(Int64(merged.count) == summary["merged_prs"]?["value"]?.intValue)
        #expect(Int64(markers.filter { $0 == true }.count) == summary["ai_assisted_merges"]?["value"]?.intValue)
        #expect(Int64(markers.filter { $0 == true || $0 == false }.count) == summary["ai_assisted_merges"]?["of"]?.intValue)
        let unrecorded = markers.filter { marker in
            if case .none = marker { return true }
            return false
        }
        #expect(Int64(unrecorded.count) == summary["ai_assisted_merges"]?["unrecorded"]?.intValue)
    }

    @Test func theVerifierStillPassesAndAnEditedSentenceBreaksTheDigest() throws {
        let (_, _, proof) = try Self.proof()
        let pass = try T.python(try T.write(proof.bytes))
        #expect(pass.status == 0, "\(pass.output)")
        let text = String(decoding: proof.bytes, as: UTF8.self)
        let edited = text.replacingOccurrences(of: "Your agent logged 2 entries", with: "Your agent logged 29 entries")
        #expect(edited != text)
        let fail = try T.python(try T.write(Array(edited.utf8)))
        #expect(fail.status == 1 && fail.output.contains("export_digest does not match"))
    }

    @Test func theSameStoreStillGivesTheSameBytes() throws {
        let (store, clock, a) = try Self.proof()
        let b = try ProofExporter.export(store, T.request(clock))
        #expect(a.bytes == b.bytes)
    }

    @Test func theFiguresAreNullWhenThereIsNoRecordAndTheSentenceSaysNothing() throws {
        let (store, clock) = try T.october()
        var request = T.request(clock)
        request.from = LocalDate("2026-10-05")!
        request.to = LocalDate("2026-10-09")!
        let proof = try ProofExporter.export(store, request)
        let summary = Self.summary(proof)
        #expect(summary["agent_entries"]?["value"] == .null)
        #expect(summary["review_sentence"]?["text"] == .null)
        #expect(summary["review_sentence"]?["definition"]?.stringValue?.isEmpty == false)
        #expect(try T.python(try T.write(proof.bytes)).status == 0)
    }

    @Test func withNoGitHubRecordMarkersAreNullAndAnAgentCountOfZeroIsKnown() throws {
        let clock = ManualClock(Timestamp.parse("2026-10-28T04:00:00Z")!)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        try store.ensureGenesis(profile: ["timezone": .string(T.zone)])
        try store.append([EventPayload.entryCreated(T.entry("E1", day: "2026-10-28", title: "Fixed the flaky test")).draft(actor: .cli)])
        let summary = Self.summary(try ProofExporter.export(store, T.request(clock)))
        for key in ["value", "of", "percent", "unrecorded"] { #expect(summary["ai_assisted_merges"]?[key] == .null, "\(key)") }
        #expect(summary["agent_entries"]?["value"] == 0)
        #expect(summary["review_sentence"]?["text"] == "Your agent logged 0 entries you accepted.")
    }
}
