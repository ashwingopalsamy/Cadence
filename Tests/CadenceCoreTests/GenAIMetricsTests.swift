import Foundation
import Testing

@testable import CadenceCore

/// docs/SPEC.md section 11.1: AI-assisted merges, agent-logged entries, median session length, cache reuse and
/// model mix, plus the sentence a review needs. Seeded ledgers, and for every metric the unknown case.
@Suite struct GenAIMetricsTests {
    typealias S = SummaryTests

    // MARK: seeding

    static func entry(
        _ id: String, day: String, kind: EntryKind = .workDone, origin: Origin = .selfReported, source: String? = nil,
        ai: Bool? = nil, status: EntryStatus = .accepted, export: ExportPolicy = .include
    ) -> Entry {
        Entry(
            id: id, day: day, kind: kind, family: EntryKind.family(for: kind, ticketClass: nil), title: "Entry \(id)",
            occurredAt: "\(day)T15:00:00+05:30", attrs: ai.map { ["ai_assisted": .bool($0)] } ?? [:], origin: origin,
            source: source, sourceRef: source.map { "\($0):\(id)" }, status: status, export: export)
    }

    static func create(_ entry: Entry, actor: Actor = .cli) -> EventDraft { EventPayload.entryCreated(entry).draft(actor: actor) }

    static func merged(_ id: String, day: String, ai: Bool?) -> EventDraft {
        create(entry(id, day: day, kind: .prMerged, origin: .collected, source: "github", ai: ai), actor: .collector("github"))
    }

    static func change(_ id: String, to status: EntryStatus) -> EventDraft {
        EventPayload.entryStatus(EntryStatusChange(from: .accepted, to: status)).draft(actor: .cli, id: id)
    }

    static func session(_ id: String, day: String, start: String, end: String? = nil) -> EventDraft {
        EventPayload.genaiSession(GenAISession(
            sessionId: id, tool: "claude-code", day: day, startedAt: "\(day)T\(start):00+05:30",
            endedAt: end.map { "\(day)T\($0):00+05:30" })).draft(actor: .hook)
    }

    static func usage(
        _ day: String, _ source: String, model: String, input: Int64?, output: Int64?, cacheRead: Int64?
    ) -> EventDraft {
        EventPayload.genaiUsage(GenAIUsage(
            day: day, tool: "claude-code", model: model, source: source, sessions: nil, requests: nil,
            tokens: TokenCounts(input: input, output: output, cacheRead: cacheRead, cacheWrite: nil), costMicros: nil,
            estimated: false)).draft(actor: .collector("claude-code"))
    }

    /// The proof tests' October with PR and agent entries on the 29th (the 28th keeps its one PR with no marker).
    static func seeded() throws -> (Journal, SQLiteStore, ManualClock) {
        let (journal, store, clock) = try S.journal()
        try seed(store)
        return (journal, store, clock)
    }

    /// PR and agent entries on the 29th, 28th and 31st (the 28th keeps the proof October's PR, which has no marker).
    static func seed(_ store: SQLiteStore) throws {
        try store.append([
            merged("M1", day: "2026-10-29", ai: true), merged("M2", day: "2026-10-29", ai: true),
            merged("M3", day: "2026-10-29", ai: false),
            // None of these are merged PRs from the collector, or none are in range or accepted.
            create(entry("M4", day: "2026-10-29", kind: .prMerged, ai: true)),
            create(entry("M5", day: "2026-10-29", kind: .prOpened, origin: .collected, source: "github", ai: true), actor: .collector("github")),
            create(entry("M6", day: "2026-10-29", kind: .prMerged, origin: .collected, source: "github", ai: true), actor: .collector("github")),
            change("M6", to: .dismissed),
            merged("M7", day: "2026-10-31", ai: true),
            create(entry("G1", day: "2026-10-28", origin: .agent), actor: .mcp),
            create(entry("G2", day: "2026-10-29", origin: .agent), actor: .mcp),
            create(entry("G3", day: "2026-10-29", origin: .agent, status: .proposed), actor: .mcp),
            create(entry("G4", day: "2026-10-29", origin: .agent), actor: .mcp), change("G4", to: .dismissed),
            create(entry("G5", day: "2026-10-29", origin: .agent), actor: .mcp), change("G5", to: .deleted),
            create(entry("G6", day: "2026-10-31", origin: .agent), actor: .mcp),
            create(entry("G7", day: "2026-10-29", origin: .agent, export: .exclude), actor: .mcp),
        ])
    }

    // MARK: percent

    @Test func percentRoundsHalfUpAndNeverShowsAPartialShareAsNoneOrAll() {
        #expect(GenAIMetrics.percent(9, of: 14) == 64)
        #expect(GenAIMetrics.percent(2, of: 3) == 67)
        #expect(GenAIMetrics.percent(1, of: 2) == 50)
        #expect(GenAIMetrics.percent(0, of: 5) == 0)
        #expect(GenAIMetrics.percent(5, of: 5) == 100)
        #expect(GenAIMetrics.percent(199, of: 200) == 99)  // 99.5 rounds to 100 but 1 is missing
        #expect(GenAIMetrics.percent(1, of: 300) == 1)  // 0.33 rounds to 0 but something is there
        #expect(GenAIMetrics.percent(0, of: 0) == nil)
        #expect(GenAIMetrics.percent(3, of: 0) == nil)
    }

    // MARK: AI-assisted merges

    @Test func assistedMergesCountMarkedPRsOutOfRecordedOnes() {
        #expect(GenAIMetrics.assistedMerges([true, true, false]) == AssistedMerges(share: Share(2, of: 3), unrecorded: 0))
        // A PR whose marker was never recorded is neither assisted nor unassisted: it is left out and counted.
        #expect(GenAIMetrics.assistedMerges([true, nil, false, nil]) == AssistedMerges(share: Share(1, of: 2), unrecorded: 2))
        // No merged PR is a known zero out of zero; merged PRs with no recorded marker are unknown.
        #expect(GenAIMetrics.assistedMerges([]) == AssistedMerges(share: Share(0, of: 0), unrecorded: 0))
        #expect(GenAIMetrics.assistedMerges([nil, nil]) == nil)
    }

    @Test func theMarkerIsReadFromAttrs() {
        #expect(GenAIMetrics.marker(inAttrs: #"{"ai_assisted":true,"number":4}"#) == true)
        #expect(GenAIMetrics.marker(inAttrs: #"{"ai_assisted":false}"#) == false)
        #expect(GenAIMetrics.marker(inAttrs: #"{"number":4}"#) == nil)
        #expect(GenAIMetrics.marker(inAttrs: #"{"ai_assisted":"yes"}"#) == nil)
        #expect(GenAIMetrics.marker(inAttrs: "not json") == nil)
        #expect(GenAIMetrics.marker(inAttrs: nil) == nil)
    }

    @Test func assistedMergesInASeededRange() throws {
        let (journal, _, _) = try Self.seeded()
        // 27 to 30 Oct: the 28th's PR (E1) has no recorded marker; the 29th has two marked, one not.
        let all = try journal.summary(from: LocalDate("2026-10-27")!, to: LocalDate("2026-10-30")!)
        #expect(all.mergedPRs == 4)
        #expect(all.assistedMerges == AssistedMerges(share: Share(2, of: 3), unrecorded: 1))
        #expect(all.assistedMerges?.share.percent == 67)
        let late = try journal.summary(from: LocalDate("2026-10-29")!, to: LocalDate("2026-10-30")!)
        #expect(late.assistedMerges == AssistedMerges(share: Share(2, of: 3), unrecorded: 0))
    }

    @Test func assistedMergesAreUnknownWithoutARecordedMarkerAndZeroOutOfZeroWithoutMergedPRs() throws {
        let (journal, store, _) = try Self.seeded()
        // The 28th holds one merged PR and no marker: unknown, not 0 of 1.
        let only = try journal.summary(from: LocalDate("2026-10-28")!, to: LocalDate("2026-10-28")!)
        #expect(only.mergedPRs == 1 && only.assistedMerges == nil)
        // Before the ledger began there is no record at all.
        let before = try journal.summary(from: LocalDate("2026-10-05")!, to: LocalDate("2026-10-09")!)
        #expect(before.assistedMerges == nil)
        // The 27th has an entry but no merged PR: a known 0 of 0, which has no percentage.
        try store.append([Self.create(Self.entry("N1", day: "2026-10-27"))])
        let quiet = try journal.summary(from: LocalDate("2026-10-27")!, to: LocalDate("2026-10-27")!)
        #expect(quiet.assistedMerges == AssistedMerges(share: Share(0, of: 0), unrecorded: 0))
        #expect(quiet.assistedMerges?.share.percent == nil)
        #expect(quiet.json.objectValue?["ai"]?["assisted_merges"]?["percent"] == .null)
    }

    // MARK: agent-logged entries

    @Test func agentEntriesAreAcceptedEntriesWithOriginAgent() throws {
        let (journal, _, _) = try Self.seeded()
        // G1 (28th), G2 and G7 (29th, excluded from a proof but accepted). Proposed, dismissed, deleted and
        // out-of-range ones are not counted.
        let summary = try journal.summary(from: LocalDate("2026-10-27")!, to: LocalDate("2026-10-30")!)
        #expect(summary.agentEntries == 3)
        #expect(summary.json.objectValue?["ai"]?["agent_entries"]?["value"] == 3)
    }

    @Test func agentEntriesAreAKnownZeroWithEntriesAndUnknownWithout() throws {
        let (journal, _, _) = try S.journal()
        // The proof October has accepted entries in range and none from an agent.
        let none = try journal.summary(from: LocalDate("2026-10-27")!, to: LocalDate("2026-10-30")!)
        #expect(none.agentEntries == 0)
        let before = try journal.summary(from: LocalDate("2026-10-05")!, to: LocalDate("2026-10-09")!)
        #expect(before.agentEntries == nil)
        #expect(before.json.objectValue?["ai"]?["agent_entries"]?["value"] == .null)
    }

    // MARK: session length

    @Test func sessionLengthIsTheMedianOfMeasuredSessions() throws {
        let (journal, store, _) = try S.journal()
        try store.append([
            Self.session("S1", day: "2026-10-29", start: "10:00", end: "10:42"),  // 2520 s
            Self.session("S2", day: "2026-10-29", start: "11:00"),  // still open: not measured
            Self.session("S3", day: "2026-10-29", start: "14:00", end: "14:30"),  // 1800 s
            Self.session("S4", day: "2026-10-28", start: "15:00", end: "14:00"),  // ends before it starts: not measured
            Self.session("S5", day: "2026-10-28", start: "16:00"),
            Self.session("S5", day: "2026-10-28", start: "16:00", end: "17:15"),  // the end arrives as its own event: 4500 s
            Self.session("S6", day: "2026-10-31", start: "10:00", end: "10:05"),  // outside the range
        ])
        let range = (LocalDate("2026-10-27")!, LocalDate("2026-10-30")!)
        let odd = try journal.summary(from: range.0, to: range.1)
        #expect(odd.aiSessions == 5)
        #expect(odd.sessionLength == SessionLength(medianSeconds: 2520, measured: 3, sessions: 5))
        // A fourth measured session makes the median the mean of the middle two, in whole seconds.
        try store.append([Self.session("S7", day: "2026-10-30", start: "10:00", end: "10:10")])  // 600 s
        let even = try journal.summary(from: range.0, to: range.1)
        #expect(even.sessionLength == SessionLength(medianSeconds: 2160, measured: 4, sessions: 6))
        let json = try #require(even.json.objectValue?["ai"]?["session_length"])
        #expect(json["median_seconds"] == 2160 && json["measured"] == 4 && json["of"] == 6)
        #expect(json["definition"]?.stringValue?.isEmpty == false)
    }

    @Test func sessionLengthIsUnknownWithoutAMeasuredSession() throws {
        let (journal, store, _) = try S.journal()
        let range = (LocalDate("2026-10-27")!, LocalDate("2026-10-30")!)
        // No hook has ever run.
        let none = try journal.summary(from: range.0, to: range.1)
        #expect(none.aiSessions == nil && none.sessionLength == nil)
        #expect(none.json.objectValue?["ai"]?["session_length"]?["median_seconds"] == .null)
        // Sessions exist but every one is still open: sessions are known, their length is not.
        try store.append([Self.session("S1", day: "2026-10-29", start: "10:00"), Self.session("S2", day: "2026-10-29", start: "12:00")])
        let open = try journal.summary(from: range.0, to: range.1)
        #expect(open.aiSessions == 2 && open.sessionLength == nil)
        // A range that ends before the first session has no record.
        let before = try journal.summary(from: LocalDate("2026-10-05")!, to: LocalDate("2026-10-09")!)
        #expect(before.aiSessions == nil && before.sessionLength == nil)
    }

    @Test func aSessionOfSecondsIsKept() {
        let one = GenAIMetrics.sessionLength([
            (started: "2026-10-29T10:00:00+05:30", ended: "2026-10-29T10:00:30+05:30"),
            (started: "2026-10-29T10:00:00+05:30", ended: "not a time"),
            (started: "garbage", ended: "2026-10-29T10:00:30+05:30"),
        ])
        #expect(one == SessionLength(medianSeconds: 30, measured: 1, sessions: 3))
        #expect(GenAIMetrics.sessionLength([]) == nil)
    }

    // MARK: cache reuse and model mix

    /// Day 27 from the import, day 29 from the endpoint (the transcripts row loses and is never added), day 30 with
    /// nothing known. The 28th keeps the proof October's transcripts row, which has no token counts.
    static func usageSeed(_ store: SQLiteStore) throws {
        try store.append([
            usage("2026-10-27", "import", model: "claude-opus", input: 100, output: 400, cacheRead: 300),
            usage("2026-10-29", "endpoint", model: "claude-opus", input: 200, output: 1000, cacheRead: 800),
            usage("2026-10-29", "endpoint", model: "claude-sonnet", input: nil, output: 600, cacheRead: 100),
            usage("2026-10-29", "transcripts", model: "claude-opus", input: 9999, output: 9999, cacheRead: 9999),
            usage("2026-10-30", "endpoint", model: "claude-haiku", input: 0, output: nil, cacheRead: 0),
        ])
    }

    @Test func cacheReuseIsCacheReadOverInputPlusCacheRead() throws {
        let (journal, store, _) = try S.journal()
        try Self.usageSeed(store)
        let summary = try journal.summary(from: LocalDate("2026-10-27")!, to: LocalDate("2026-10-30")!)
        // Rows that report input and cache read: 300 of 100 + 300, and 800 of 200 + 800. The sonnet row has no
        // input, the haiku row has nothing to divide, and the transcripts row was not picked.
        #expect(summary.cacheReuse == CacheReuse(cacheRead: 1100, input: 300, sources: ["endpoint": 1, "import": 1]))
        #expect(summary.cacheReuse?.percent == 79)  // 1100 of 1400 is 78.57
        let json = try #require(summary.json.objectValue?["ai"]?["cache_reuse"])
        #expect(json["percent"] == 79 && json["cache_read_tokens"] == 1100 && json["input_tokens"] == 300)
        #expect(json["sources"] == ["endpoint": 1, "import": 1])
        #expect(json["definition"]?.stringValue?.isEmpty == false)
    }

    @Test func modelMixIsTheShareOfOutputTokensByModelFromThePick() throws {
        let (journal, store, _) = try S.journal()
        try Self.usageSeed(store)
        let summary = try journal.summary(from: LocalDate("2026-10-27")!, to: LocalDate("2026-10-30")!)
        // Opus 400 + 1000, sonnet 600. The transcripts opus row and the haiku row (output unknown) add nothing.
        let mix = try #require(summary.modelMix)
        #expect(mix.models == [ModelShare(model: "claude-opus", outputTokens: 1400), ModelShare(model: "claude-sonnet", outputTokens: 600)])
        #expect(mix.totalOutputTokens == 2000 && mix.sources == ["endpoint": 1, "import": 1])
        #expect(mix.percent(of: mix.models[0]) == 70 && mix.percent(of: mix.models[1]) == 30)
        #expect(summary.outputTokens == 2000)  // the mix and the output tokens line read the same rows
        let json = try #require(summary.json.objectValue?["ai"]?["model_mix"])
        #expect(json["total_output_tokens"] == 2000)
        #expect(json["models"] == [
            ["model": "claude-opus", "output_tokens": 1400, "percent": 70],
            ["model": "claude-sonnet", "output_tokens": 600, "percent": 30],
        ])
    }

    @Test func aSourceIsNeverSummedWithAnotherInTheMix() throws {
        let (journal, store, _) = try S.journal()
        try store.append([
            Self.usage("2026-10-29", "transcripts", model: "claude-opus", input: 10, output: 500, cacheRead: 40),
            Self.usage("2026-10-29", "endpoint", model: "claude-sonnet", input: 10, output: 100, cacheRead: 10),
        ])
        let summary = try journal.summary(from: LocalDate("2026-10-29")!, to: LocalDate("2026-10-29")!)
        #expect(summary.modelMix?.models == [ModelShare(model: "claude-sonnet", outputTokens: 100)])
        #expect(summary.cacheReuse == CacheReuse(cacheRead: 10, input: 10, sources: ["endpoint": 1]))
    }

    @Test func cacheReuseAndModelMixAreUnknownWithoutKnownTokens() throws {
        let (journal, store, _) = try S.journal()
        // The proof October's only usage row (28th, transcripts) has no token counts at all.
        let bare = try journal.summary(from: LocalDate("2026-10-28")!, to: LocalDate("2026-10-28")!)
        #expect(bare.cacheReuse == nil && bare.modelMix == nil)
        // Zero input and zero cache read has nothing to divide; an unknown output adds no model.
        try Self.usageSeed(store)
        let thirty = try journal.summary(from: LocalDate("2026-10-30")!, to: LocalDate("2026-10-30")!)
        #expect(thirty.cacheReuse == nil && thirty.modelMix == nil)
        // Known outputs that are all zero have no shares.
        try store.append([Self.usage("2026-10-26", "import", model: "claude-opus", input: 5, output: 0, cacheRead: 0)])
        let zero = try journal.summary(from: LocalDate("2026-10-26")!, to: LocalDate("2026-10-26")!)
        #expect(zero.modelMix == nil)
        #expect(zero.cacheReuse == CacheReuse(cacheRead: 0, input: 5, sources: ["import": 1]))
        #expect(zero.cacheReuse?.percent == 0)  // a known 0%: five input tokens and no cache read
        let json = try #require(bare.json.objectValue?["ai"])
        #expect(json["cache_reuse"]?["percent"] == .null && json["cache_reuse"]?["sources"] == .null)
        #expect(json["model_mix"]?["models"] == .null)
    }

    // MARK: the sentence

    @Test func theSentenceIsTheSpecsWhenEveryFigureIsKnown() {
        let text = ReviewSentence.make(
            aiDays: Share(17, of: 19), assisted: AssistedMerges(share: Share(9, of: 14), unrecorded: 0), agentEntries: 31)
        #expect(text == "AI on 17 of 19 workdays. 64% of merged PRs were AI-assisted. Your agent logged 31 entries you accepted.")
    }

    @Test func theSentenceLeavesUnknownFiguresOutAndStatesKnownZeros() {
        let none = AssistedMerges(share: Share(0, of: 0), unrecorded: 0)
        #expect(ReviewSentence.make(aiDays: nil, assisted: nil, agentEntries: nil) == nil)
        #expect(ReviewSentence.make(aiDays: Share(0, of: 0), assisted: none, agentEntries: nil) == nil)  // nothing to say
        #expect(ReviewSentence.make(aiDays: nil, assisted: nil, agentEntries: 1) == "Your agent logged 1 entry you accepted.")
        #expect(ReviewSentence.make(aiDays: Share(1, of: 1), assisted: none, agentEntries: 0) == "AI on 1 of 1 workday. Your agent logged 0 entries you accepted.")
        #expect(ReviewSentence.make(aiDays: Share(0, of: 4), assisted: AssistedMerges(share: Share(0, of: 2), unrecorded: 0), agentEntries: nil)
            == "AI on 0 of 4 workdays. 0% of merged PRs were AI-assisted.")
        #expect(ReviewSentence.make(aiDays: nil, assisted: AssistedMerges(share: Share(199, of: 200), unrecorded: 0), agentEntries: nil)
            == "99% of merged PRs were AI-assisted.")
    }

    @Test func theSentenceSaysWhenPRsWithNoRecordedMarkerWereLeftOut() {
        #expect(ReviewSentence.make(aiDays: nil, assisted: AssistedMerges(share: Share(2, of: 3), unrecorded: 1), agentEntries: nil)
            == "67% of the 3 merged PRs with a recorded marker were AI-assisted.")
        #expect(ReviewSentence.make(aiDays: nil, assisted: AssistedMerges(share: Share(1, of: 1), unrecorded: 4), agentEntries: nil)
            == "100% of the 1 merged PR with a recorded marker was AI-assisted.")
    }

    @Test func theCycleSummaryCarriesTheSentenceBuiltFromItsOwnFigures() throws {
        let (journal, _, _) = try Self.seeded()
        let summary = try journal.summary(from: LocalDate("2026-10-27")!, to: LocalDate("2026-10-30")!)
        // AI on the 28th only (a usage row), out of the counted days from the first AI day: the 28th and 29th.
        #expect(summary.aiDays == 1 && summary.aiCountedDays == 2)
        #expect(summary.reviewSentence
            == "AI on 1 of 2 workdays. 67% of the 3 merged PRs with a recorded marker were AI-assisted. Your agent logged 3 entries you accepted.")
        let json = try #require(summary.json.objectValue?["review_sentence"])
        #expect(json["text"]?.stringValue == summary.reviewSentence)
        #expect(json["definition"]?.stringValue?.contains("computed by Cadence") == true)

        // The cycle range itself reads the same ledger from 1 October.
        let cycle = try journal.summary(.cycle)
        #expect(cycle.label == "cycle" && cycle.from == LocalDate("2026-10-01")!)
        #expect(cycle.assistedMerges == AssistedMerges(share: Share(2, of: 3), unrecorded: 1))
        #expect(cycle.agentEntries == 3)  // G1, G2 and G7; the 31st is outside the cycle so far
    }

    @Test func theSentenceIsNullWhenNothingIsKnown() throws {
        let (journal, _, _) = try S.journal()
        let before = try journal.summary(from: LocalDate("2026-10-05")!, to: LocalDate("2026-10-09")!)
        #expect(before.reviewSentence == nil)
        let json = try #require(before.json.objectValue?["review_sentence"])
        #expect(json["text"] == .null)
        #expect(json["definition"]?.stringValue?.isEmpty == false)
    }

    // MARK: rendering

    @Test func theHumanSummaryShowsEachMetricAndLabelsTheSentence() throws {
        let (journal, store, _) = try Self.seeded()
        try Self.usageSeed(store)
        try store.append([Self.session("S1", day: "2026-10-29", start: "10:00", end: "10:42")])
        let text = SummaryRendering.human(try journal.summary(from: LocalDate("2026-10-27")!, to: LocalDate("2026-10-30")!))
        let lines = text.components(separatedBy: "\n")
        func row(_ label: String) -> String? { lines.first { $0.hasPrefix(label) } }
        #expect(lines.contains("The sentence your review needs"))
        let at = try #require(lines.firstIndex(of: "The sentence your review needs"))
        #expect(lines[at + 1].hasPrefix("AI on "))
        #expect(lines[at + 2].contains("Computed by Cadence from the figures below"))
        #expect(row("AI-assisted merges")?.contains("2 of 3 (67%)") == true)
        #expect(row("AI-assisted merges")?.contains("1 without a recorded marker") == true)
        #expect(row("Agent-logged entries")?.hasSuffix("3") == true)
        #expect(row("AI session length")?.contains("median 42m over 1 of 1 session") == true)
        #expect(row("Cache reuse")?.contains("79% (1100 cache read of 1400 input and cache read tokens) from endpoint (1 day), import (1 day)") == true)
        #expect(row("Model mix")?.contains("claude-opus 70%, claude-sonnet 30% of output tokens") == true)
        #expect(!text.contains("\u{2013}") && !text.contains("\u{2014}"))
    }

    @Test func theHumanSummaryUsesDashesForWhatIsUnknown() throws {
        let (journal, _, _) = try S.journal()
        let text = SummaryRendering.human(try journal.summary(from: LocalDate("2026-10-05")!, to: LocalDate("2026-10-09")!))
        let lines = text.components(separatedBy: "\n")
        func row(_ label: String) -> String? { lines.first { $0.hasPrefix(label) } }
        for label in ["AI-assisted merges", "Agent-logged entries", "AI session length", "Cache reuse", "Model mix"] {
            #expect(row(label)?.hasSuffix("-") == true, "\(label)")
        }
        #expect(lines.contains("The sentence your review needs: -"))
    }

    @Test func theSummaryStillNeverWritesToTheLedger() throws {
        let (journal, store, _) = try Self.seeded()
        try Self.usageSeed(store)
        let before = try store.eventCount()
        _ = try journal.summary(.cycle)
        #expect(try store.eventCount() == before)
    }
}
