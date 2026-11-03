import Foundation
import Testing

@testable import CadenceCore

/// docs/SPEC.md section 10.4. Fixtures are synthetic: Tests/Vectors/transcripts.
@Suite struct TranscriptsCollectorTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A scratch copy of the fixture tree, so tests can append to files and remove them.
    struct Fixture {
        let root = TestStore.tempDirectory()
        var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }
        var state: URL { root.appendingPathComponent("state/claude-code-transcripts.json") }

        init() throws {
            try FileManager.default.copyItem(
                at: Vectors.root.appendingPathComponent("transcripts/projects", isDirectory: true), to: projects)
        }

        func collector(prices: [String: JSONValue]? = nil) -> TranscriptsCollector {
            TranscriptsCollector(
                projectsDir: projects, stateFile: state, zone: TranscriptsCollectorTests.zone, boundary: .standard,
                prices: prices)
        }

        func run(
            prices: [String: JSONValue]? = nil, since: String = "2026-10-26", until: String = "2026-10-29"
        ) throws -> TranscriptsCollector.Output {
            try collector(prices: prices).run(
                name: "claude-code", runID: "01JBY0M8R2", now: TranscriptsCollectorTests.now, since: LocalDate(since)!,
                until: LocalDate(until)!)
        }
    }

    static func lines(_ output: TranscriptsCollector.Output) -> [String] {
        String(decoding: output.envelope, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static func records(_ output: TranscriptsCollector.Output) throws -> [[String: JSONValue]] {
        try lines(output).dropFirst().map {
            guard case .object(let o) = try JSONParser.parse($0) else { throw CadenceError.validation("not an object") }
            return o
        }
    }

    static func record(_ output: TranscriptsCollector.Output, _ ref: String) throws -> [String: JSONValue] {
        try #require(try records(output).first { $0["source_ref"] == .string(ref) })
    }

    static func tokens(_ record: [String: JSONValue]) throws -> [String: Int64] {
        guard case .object(let t) = try #require(record["tokens"]) else { return [:] }
        return t.compactMapValues { if case .int(let n) = $0 { n } else { nil } }
    }

    // MARK: Line scanner

    static func scan(_ text: String) -> TranscriptUsageLine? { TranscriptLineScanner.scan(Array(text.utf8)) }

    @Test func scannerReadsOnlyTheFiveFields() throws {
        let line = try #require(
            Self.scan(
                #"{"type":"assistant","costUSD":0.5e-2,"sessionId":"sé","timestamp":"2026-10-28T05:01:00.000Z","message":{"id":"m1","model":"model-a","stop":null,"usage":{"input_tokens":3,"output_tokens":4,"cache_creation_input_tokens":5,"cache_read_input_tokens":6,"extra":{"a":[1,2.5]}}}}"#
            ))
        #expect(line.messageID == "m1")
        #expect(line.model == "model-a")
        #expect(line.sessionID == "sé")
        #expect(line.input == 3 && line.output == 4 && line.cacheWrite == 5 && line.cacheRead == 6)
        #expect(line.timestamp == 1_793_163_660)
    }

    @Test func scannerIgnoresLinesWithoutAnIDOrUsage() {
        #expect(Self.scan(#"{"sessionId":"s","timestamp":"2026-10-28T05:01:00Z","message":{"role":"user","content":"hi"}}"#) == nil)
        #expect(Self.scan(#"{"sessionId":"s","timestamp":"2026-10-28T05:01:00Z","message":{"id":"m1","model":"model-a"}}"#) == nil)
        #expect(Self.scan(#"{"sessionId":"s","timestamp":"2026-10-28T05:01:00Z","message":{"usage":{"output_tokens":1}}}"#) == nil)
        #expect(Self.scan(#"{"type":"summary","summary":"x"}"#) == nil)
        #expect(Self.scan(#"{"message":{"id":"m1","usage":{"output_tokens":1}}}"#) == nil, "no timestamp")
        #expect(Self.scan("") == nil)
    }

    @Test func scannerIgnoresMalformedLines() {
        #expect(Self.scan(#"{"sessionId":"s","timestamp":"2026-10-28T05:01:00Z","message":{"id":"m1","usage":{"output_tokens":"#) == nil)
        #expect(Self.scan(#"not json"#) == nil)
        #expect(Self.scan(#"{"message":{"id":"m1","usage":{"output_tokens":-1}},"timestamp":"2026-10-28T05:01:00Z"}"#) == nil)
        #expect(Self.scan(#"{"message":{"id":"m1","usage":{"output_tokens":1.5}},"timestamp":"2026-10-28T05:01:00Z"}"#) == nil)
    }

    /// The scanner never builds a value for anything but the five fields. This line proves it: the content holds
    /// bytes that are not UTF-8, a string that never closes inside an escape-looking run, and a decoy `id` and
    /// `usage` that a decoder which looked inside content would pick up. A Foundation decoder rejects the whole line
    /// for the invalid bytes alone. The scanner steps over them and still reads the real fields.
    @Test func messageContentIsNeverDecoded() throws {
        var bytes = Array(
            #"{"type":"assistant","sessionId":"s","timestamp":"2026-10-28T05:01:00.000Z","message":{"id":"real","model":"model-a","content":["#
                .utf8)
        bytes += Array(#"{"type":"text","text":"bad bytes: "#.utf8) + [0xFF, 0xFE, 0xC0, 0x80] + Array(#" \\\" ok","#.utf8)
        bytes += Array(#""id":"decoy","usage":{"output_tokens":999999}}"#.utf8)
        bytes += Array(#"],"usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}"#.utf8)

        #expect((try? JSONSerialization.jsonObject(with: Data(bytes))) == nil, "the line is not valid UTF-8 JSON")
        let line = try #require(TranscriptLineScanner.scan(bytes))
        #expect(line.messageID == "real")
        #expect(line.output == 2)
        #expect(line.input == 1 && line.cacheWrite == 3 && line.cacheRead == 4)
    }

    @Test func scannerSurvivesHugeContent() throws {
        let text = String(repeating: "x\\\"y{[", count: 200_000)
        let line = try #require(
            Self.scan(
                #"{"timestamp":"2026-10-28T05:01:00Z","message":{"content":"\#(text)","id":"m1","usage":{"output_tokens":9}}}"#))
        #expect(line.output == 9)
    }

    // MARK: Totals

    @Test func totalsPerLocalDayAndModel() throws {
        let f = try Fixture()
        let out = try f.run()
        let head = try #require(Self.lines(out).first)
        #expect(
            head
                == #"{"cadence":"envelope/1","collector":"claude-code","generated_at":"2026-09-21T19:43:20+05:30","run":"01JBY0M8R2","window":{"since":"2026-10-26","until":"2026-10-29"}}"#
        )

        let records = try Self.records(out)
        #expect(
            records.map { $0["source_ref"] }.compactMap { v -> String? in if case .string(let s) = v { s } else { nil } }
                == [
                    "claude-code:2026-10-27:model-a", "claude-code:2026-10-28:model-a", "claude-code:2026-10-28:model-b",
                    "claude-code:2026-10-29:model-a",
                ])

        // Streaming duplicate msg_01 keeps the line with 40 output tokens; msg_02 appears in two files and counts once.
        let a28 = try Self.record(out, "claude-code:2026-10-28:model-a")
        #expect(a28["type"] == .string("genai.usage"))
        #expect(a28["tool"] == .string("claude-code"))
        #expect(a28["day"] == .string("2026-10-28"))
        #expect(a28["model"] == .string("model-a"))
        #expect(a28["sessions"] == .int(2))
        #expect(a28["requests"] == .int(3))
        #expect(try Self.tokens(a28) == ["in": 35, "out": 115, "cache_read": 300, "cache_write": 50])
        #expect(a28["cost_micros"] == nil && a28["estimated"] == nil)

        // 22:00Z is 03:30 in Kolkata: before the 04:00 boundary, so still the 28th. 22:30Z is 04:00: the 29th.
        let b28 = try Self.record(out, "claude-code:2026-10-28:model-b")
        #expect(b28["sessions"] == .int(1) && b28["requests"] == .int(1))
        #expect(try Self.tokens(b28) == ["in": 7, "out": 8, "cache_read": 9, "cache_write": 10])
        let a29 = try Self.record(out, "claude-code:2026-10-29:model-a")
        #expect(try Self.tokens(a29) == ["in": 1, "out": 2, "cache_read": 3, "cache_write": 4])
    }

    @Test func onlyDaysInTheWindowAreEmitted() throws {
        let f = try Fixture()
        let out = try f.run(since: "2026-10-28", until: "2026-10-28")
        let refs = try Self.records(out).map { $0["source_ref"] }
        #expect(refs == [.string("claude-code:2026-10-28:model-a"), .string("claude-code:2026-10-28:model-b")])
        let none = try f.run(since: "2026-01-01", until: "2026-01-02")
        #expect(Self.lines(none).count == 1)
    }

    @Test func headerUsesTheGivenName() throws {
        let f = try Fixture()
        let out = try f.collector().run(
            name: "claude-code-work", runID: "R1", now: Self.now, since: LocalDate("2026-10-28")!, until: LocalDate("2026-10-28")!)
        #expect(try #require(Self.lines(out).first).contains(#""collector":"claude-code-work""#))
    }

    @Test func missingProjectsFolderGivesAnEmptyEnvelope() throws {
        let f = try Fixture()
        try FileManager.default.removeItem(at: f.projects)
        let out = try f.run()
        #expect(Self.lines(out).count == 1)
    }

    // MARK: Incremental

    @Test func unchangedFilesAreNotReadAgainButTotalsStayComplete() throws {
        let f = try Fixture()
        let first = try f.run()
        #expect(first.filesRead == 2 && first.filesCached == 0)
        let second = try f.run()
        #expect(second.filesRead == 0 && second.filesCached == 2)
        #expect(second.envelope == first.envelope)

        let attributes = try FileManager.default.attributesOfItem(atPath: f.state.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aGrownFileIsReadAgainAndUpdatesTheSameRow() throws {
        let f = try Fixture()
        _ = try f.run()
        let file = f.projects.appendingPathComponent("-Users-example-acme-refunds/session-b.jsonl")
        let extra =
            #"{"type":"assistant","sessionId":"sess-c","timestamp":"2026-10-28T07:00:00.000Z","message":{"id":"msg_07","model":"model-a","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1}}}"#
            + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(extra.utf8))
        try handle.close()

        let out = try f.run()
        #expect(out.filesRead == 1 && out.filesCached == 1)
        let a28 = try Self.record(out, "claude-code:2026-10-28:model-a")
        #expect(a28["sessions"] == .int(3) && a28["requests"] == .int(4))
        #expect(try Self.tokens(a28) == ["in": 36, "out": 116, "cache_read": 301, "cache_write": 51])
    }

    @Test func aRemovedTranscriptKeepsItsDaysComplete() throws {
        let f = try Fixture()
        let first = try f.run()
        try FileManager.default.removeItem(at: f.projects.appendingPathComponent("-Users-example-acme-refunds"))
        let second = try f.run()
        #expect(second.envelope == first.envelope)
    }

    @Test func aCorruptStateFileIsRebuilt() throws {
        let f = try Fixture()
        let first = try f.run()
        try PrivateFile.save(Array("not json".utf8), to: f.state)
        let second = try f.run()
        #expect(second.filesRead == 2)
        #expect(second.envelope == first.envelope)
    }

    @Test func tildeInTheProjectsFolderIsExpanded() throws {
        let f = try Fixture()
        let collector = TranscriptsCollector(
            projectsDir: "~/projects", userHome: f.root, stateFile: f.state, zone: Self.zone, boundary: .standard, prices: nil)
        let out = try collector.run(
            name: "claude-code", runID: "R1", now: Self.now, since: LocalDate("2026-10-26")!, until: LocalDate("2026-10-29")!)
        #expect(Self.lines(out).count == 5)
    }

    // MARK: Prices

    static let prices: [String: JSONValue] = [
        "model-a": .object(["in": .int(3_000_000), "out": .int(15_000_000), "cache_read": .int(300_000), "cache_write": .int(3_750_000)])
    ]

    @Test func priceTableAddsAnEstimatedIntegerCost() throws {
        let f = try Fixture()
        let out = try f.run(prices: Self.prices)
        // 35*3000000 + 115*15000000 + 300*300000 + 50*3750000 = 2,107,500,000 micro-dollars per million = 2107.5, half up.
        let a28 = try Self.record(out, "claude-code:2026-10-28:model-a")
        #expect(a28["cost_micros"] == .int(2108))
        #expect(a28["estimated"] == .bool(true))
        let b28 = try Self.record(out, "claude-code:2026-10-28:model-b")
        #expect(b28["cost_micros"] == nil && b28["estimated"] == nil, "a model without a price has no cost")
    }

    @Test func aBadPriceTableIsRejected() throws {
        let f = try Fixture()
        for bad: JSONValue in [
            .string("free"), .object(["in": .int(-1)]), .object(["in": .string("1")]), .object(["tokens": .int(1)]),
        ] {
            #expect(throws: CadenceError.self) { _ = try f.run(prices: ["model-a": bad]) }
        }
    }

    // MARK: Ingest

    @Test func theEnvelopeIngestsAndASecondRunIsUnchanged() throws {
        let f = try Fixture()
        let clock = ManualClock(Date(timeIntervalSince1970: 1_793_300_000))
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        let journal = try Journal(
            store: store, config: Config.defaults(timezone: "Asia/Kolkata"), clock: clock, ids: CountingIDs())
        let window = IngestWindow(since: "2026-10-26", until: "2026-10-29")

        let first = try journal.ingest(
            envelope: try f.run(prices: Self.prices).envelope, collector: "claude-code", window: window)
        #expect(first.status == "ok")
        #expect(first.counts["created"] == 4 && first.counts["skipped"] == 0)

        let rows = try store.db.query("SELECT * FROM genai_usage ORDER BY day, model")
        #expect(rows.count == 4)
        let row = try #require(rows.first { $0.text("day") == "2026-10-28" && $0.text("model") == "model-a" })
        #expect(row.text("tool") == "claude-code" && row.text("source") == "claude-code")
        #expect(row.int("sessions") == 2 && row.int("requests") == 3)
        #expect(row.int("tokens_out") == 115 && row.int("cost_micros") == 2108)

        let second = try journal.ingest(
            envelope: try f.run(prices: Self.prices).envelope, collector: "claude-code", window: window)
        #expect(second.counts["unchanged"] == 4 && second.counts["created"] == 0 && second.counts["updated"] == 0)
    }
}
