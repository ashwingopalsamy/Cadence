import Foundation
import Testing

@testable import CadenceCore

/// docs/SPEC.md section 10.5.
@Suite struct MapEngineTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    static let window = IngestWindow(since: "2026-10-26", until: "2026-10-29")
    static let generatedAt = Timestamp.parse("2026-10-29T16:10:02+05:30")!

    static let endpointMap = """
        {
          "cadence": "map/1",
          "input": "json",
          "produces": "genai.usage",
          "records": "$.data[*]",
          "fields": {
            "day":                { "path": "$.date", "format": "yyyy-MM-dd" },
            "tool":               { "const": "claude-code" },
            "model":              { "path": "$.model", "default": "*" },
            "requests":           { "path": "$.request_count" },
            "tokens.in":          { "path": "$.input_tokens" },
            "tokens.out":         { "path": "$.output_tokens" },
            "tokens.cache_read":  { "path": "$.cache_read_tokens", "default": 0 },
            "tokens.cache_write": { "path": "$.cache_creation_tokens", "default": 0 },
            "cost_micros":        { "path": "$.cost_usd", "scale": 1000000 }
          },
          "source_ref": "genai-endpoint:{day}:{tool}:{model}"
        }
        """

    static func engine(_ map: String) throws -> MapEngine {
        MapEngine(map: try MapFile(bytes: Array(map.utf8), name: "test"), zone: zone, boundary: DayBoundary(hour: 4, minute: 0)!)
    }

    static func records(_ map: String, _ input: String) throws -> (records: [JSONValue], skipped: [String]) {
        let output = try engine(map).envelope(from: Array(input.utf8), collector: "endpoint", window: window, run: "r1", generatedAt: generatedAt)
        let lines = String(decoding: output.envelope, as: UTF8.self).split(separator: "\n").map(String.init)
        return (try lines.dropFirst().map { try JSONParser.parse($0) }, output.skipped)
    }

    // MARK: - Scale

    @Test func decimalTextScalesExactly() {
        #expect(Decimal10.scaled("0.4213", by: 1_000_000) == 421_300)
        #expect(Decimal10.scaled("14.21", by: 1_000_000) == 14_210_000)
        #expect(Decimal10.scaled("431.06", by: 1_000_000) == 431_060_000)
        #expect(Decimal10.scaled("0.1", by: 1_000_000) == 100_000)  // 0.1 has no exact binary float
        #expect(Decimal10.scaled("1e-3", by: 1_000_000) == 1_000)
        #expect(Decimal10.scaled("2.5E2", by: 1) == 250)
        #expect(Decimal10.scaled("12", by: 1_000_000) == 12_000_000)
        #expect(Decimal10.scaled("0.0000005", by: 1_000_000) == 1)  // half rounds away from zero
        #expect(Decimal10.scaled("0.0000004", by: 1_000_000) == 0)
        #expect(Decimal10.scaled("0.00000049", by: 1_000_000) == 0)
        #expect(Decimal10.scaled("-0.25", by: 100) == -25)
        #expect(Decimal10.scaled("12.5", by: 1, exact: true) == nil)
        #expect(Decimal10.scaled("12.0", by: 1, exact: true) == 12)
        for bad in ["", ".", "1.2.3", "abc", "1e", "--1", "0x10", "1 000", "99999999999999999999"] {
            #expect(Decimal10.scaled(bad, by: 1) == nil, "\(bad)")
        }
        #expect(Decimal10.isPowerOfTen(1) && Decimal10.isPowerOfTen(1_000_000) && !Decimal10.isPowerOfTen(250) && !Decimal10.isPowerOfTen(0))
    }

    @Test func aFloatInTheJSONScalesWithNoFloatInBetween() throws {
        let (records, skipped) = try Self.records(Self.endpointMap, """
            {"data":[{"date":"2026-10-28","model":"model-a","request_count":212,"input_tokens":48210,"output_tokens":96115,"cost_usd":0.4213}]}
            """)
        #expect(skipped.isEmpty)
        let record = try #require(records.first)
        #expect(record["cost_micros"] == 421_300)
        #expect(record["tokens"] == ["in": 48210, "out": 96115, "cache_read": 0, "cache_write": 0])
        #expect(record["source_ref"] == "genai-endpoint:2026-10-28:claude-code:model-a")
        #expect(record["type"] == "genai.usage" && record["tool"] == "claude-code" && record["day"] == "2026-10-28")
    }

    // MARK: - The whole table

    @Test func theSpecEndpointMapProducesRecordsTheIngesterAccepts() throws {
        let input = """
            {"data":[
              {"date":"2026-10-27","model":"model-a","request_count":118,"input_tokens":1,"output_tokens":51302,"cache_read_tokens":10,"cache_creation_tokens":5,"cost_usd":"14.21"},
              {"date":"2026-10-28","request_count":212,"input_tokens":2,"output_tokens":96115,"cost_usd":26.4}
            ]}
            """
        let (records, _) = try Self.records(Self.endpointMap, input)
        #expect(records.map { $0["model"] } == ["model-a", "*"])
        #expect(records.map { $0["cost_micros"] } == [14_210_000, 26_400_000])

        let clock = ManualClock(Timestamp.parse("2026-10-29T18:00:00+05:30")!)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        let journal = try Journal(store: store, config: Config.defaults(timezone: "Asia/Kolkata"), clock: clock, ids: CountingIDs())
        let output = try Self.engine(Self.endpointMap).envelope(
            from: Array(input.utf8), collector: "endpoint", window: Self.window, run: "r1", generatedAt: Self.generatedAt)
        let report = try journal.ingest(envelope: output.envelope, collector: "endpoint", window: Self.window)
        #expect(report.count("created") == 2 && report.count("skipped") == 0, "\(report.problems)")
        let again = try journal.ingest(envelope: output.envelope, collector: "endpoint", window: Self.window)
        #expect(again.count("unchanged") == 2)
    }

    @Test func pathsCoverTheWholeSubset() throws {
        let doc = try JSONParser.parse(#"{"a":{"b c":[10,{"d":20},30]},"list":[{"x":1},{"x":2}]}"#)
        #expect(try MapPath("$").select(doc) == [doc])
        #expect(try MapPath("$.a['b c'][0]").select(doc) == [10])
        #expect(try MapPath("$['a']['b c'][1].d").select(doc) == [20])
        #expect(try MapPath("$.list[*].x").select(doc) == [1, 2])
        #expect(try MapPath("$.missing.key").select(doc) == [])
        #expect(try MapPath("$.a['b c'][9]").select(doc) == [])
        for bad in ["a.b", "$..x", "$[?(@.x)]", "$.a[", "$.", "$[-1]", "$.a()", "$['open"] {
            #expect(throws: CadenceError.self, "\(bad)") { try MapPath(bad) }
        }
    }

    @Test func formatsConvertInTheProfileZone() throws {
        let map = """
            {"cadence":"map/1","input":"json","produces":"item","records":"$[*]",
             "fields":{"kind":{"const":"oncall.shift"},"title":{"path":"$.t"},"occurred_at":{"path":"$.at","format":"%@"},"attrs.n":{"path":"$.n"}},
             "source_ref":"x:{title}"}
            """
        func at(_ format: String, _ value: String) throws -> JSONValue? {
            try Self.records(map.replacingOccurrences(of: "%@", with: format), #"[{"t":"Shift","at":\#(value),"n":3}]"#).records.first?["occurred_at"]
        }
        #expect(try at("iso8601", #""2026-10-28T10:30:00Z""#) == "2026-10-28T16:00:00+05:30")
        #expect(try at("epoch-s", "1793183400") == "2026-10-28T16:00:00+05:30")
        #expect(try at("epoch-ms", #""1793183400000""#) == "2026-10-28T16:00:00+05:30")
        let record = try #require(try Self.records(map.replacingOccurrences(of: "%@", with: "iso8601"), #"[{"t":"Shift","at":"2026-10-28T10:30:00Z","n":3}]"#).records.first)
        #expect(record["attrs"] == ["n": 3])

        let dayMap = Self.endpointMap.replacingOccurrences(of: #""format": "yyyy-MM-dd""#, with: #""format": "iso8601""#)
        // 02:00 in Kolkata is before the 04:00 boundary, so it belongs to the day before.
        let early = try Self.records(dayMap, #"{"data":[{"date":"2026-10-27T20:30:00Z","output_tokens":1}]}"#).records.first
        #expect(early?["day"] == "2026-10-27")
    }

    @Test func csvRowsBecomeObjectsKeyedByHeader() throws {
        let map = Self.endpointMap.replacingOccurrences(of: #""input": "json""#, with: #""input": "csv""#)
            .replacingOccurrences(of: #""records": "$.data[*]","#, with: "")
        let csv = "\u{FEFF}date,model,request_count,input_tokens,output_tokens,cost_usd\r\n"
            + "2026-10-27,model-a,118,1,\"51302\",14.21\r\n"
            + "2026-10-28,\"model, quoted \"\"b\"\"\",212,2,96115,0.4213\r\n"
            + "\r\n"
            + "2026-10-29,model-a,oops,2,1,1\r\n"
            + "2026-10-30,short\r\n"
        let (records, skipped) = try Self.records(map, csv)
        #expect(records.count == 2)
        #expect(records[0]["requests"] == 118 && records[0]["tokens"]?["out"] == 51302 && records[0]["cost_micros"] == 14_210_000)
        #expect(records[1]["model"] == #"model, quoted "b""#)
        #expect(skipped == [
            "row at line 5: requests: 'oops' is not a whole number",
            "row at line 6: has 2 columns, the header has 6",
        ])
    }

    @Test func badRecordsAreListedAndTheRestMapped() throws {
        let input = """
            {"data":[
              {"date":"2026-10-28","model":"model-a","output_tokens":-5},
              {"date":"28/10/2026","model":"model-a"},
              {"date":"2026-10-28","model":["a","b"]},
              {"date":"2026-10-28","model":"model-a","cost_usd":"lots"},
              {"date":"2026-10-28","model":"model-b","request_count":3.5},
              {"date":"2026-10-28","model":"model-c","output_tokens":7}
            ]}
            """
        let (records, skipped) = try Self.records(Self.endpointMap, input)
        #expect(records.count == 1 && records[0]["model"] == "model-c")
        #expect(skipped == [
            "record 1: tokens.out: must not be negative",
            "record 2: day: '28/10/2026' is not yyyy-MM-dd",
            "record 3: model: must be a single value, not a list or an object",
            "record 4: cost_micros: 'lots' is not a decimal number in range",
            "record 5: requests: '3.5' is not a whole number",
        ])
    }

    @Test func aMissingSourceRefValueSkipsTheRecord() throws {
        let map = Self.endpointMap.replacingOccurrences(of: #""model":              { "path": "$.model", "default": "*" },"#, with: #""model":              { "path": "$.model" },"#)
        let (records, skipped) = try Self.records(map, #"{"data":[{"date":"2026-10-28"}]}"#)
        #expect(records.isEmpty && skipped == ["record 1: source_ref: {model} has no value"])
    }

    @Test func mapFilesAreCheckedWhenLoaded() throws {
        let cases: [(String, String)] = [
            (#""cadence": "map/1""#, #""cadence": "map/2""#),
            (#""input": "json""#, #""input": "xml""#),
            (#""produces": "genai.usage""#, #""produces": "entry.created""#),
            (#""tool":               { "const": "claude-code" },"#, #""tool": { "const": "claude-code", "path": "$.t" },"#),
            (#""tool":               { "const": "claude-code" },"#, #""colour": { "const": "red" },"#),
            (#""scale": 1000000"#, #""scale": 250"#),
            (#""requests":           { "path": "$.request_count" },"#, #""requests": { "path": "$.r[*]" },"#),
            (#""requests":           { "path": "$.request_count" },"#, #""requests": { "path": "$.r", "format": "iso8601" },"#),
            (#""genai-endpoint:{day}:{tool}:{model}""#, #""x:{nope}""#),
            (#""records": "$.data[*]""#, #""records": "$..data""#),
        ]
        for (old, new) in cases {
            let text = Self.endpointMap.replacingOccurrences(of: old, with: new)
            #expect(text != Self.endpointMap, "\(old)")
            #expect(throws: CadenceError.self, "\(new)") { try MapFile(bytes: Array(text.utf8), name: "bad") }
        }
    }

    @Test func numbersKeepTheirTextOnlyWhenAsked() throws {
        #expect(try JSONParser.parseKeepingNumberText(bytes: Array(#"[1, 0.4213, 1e3, 12345678901234567890, -0.5]"#.utf8))
            == [1, "0.4213", "1e3", "12345678901234567890", "-0.5"])
        #expect(throws: JSONParser.Failure.self) { try JSONParser.parse("0.5") }
        for bad in ["01", "1.", ".5", "1e", "-", "1.e3"] {
            #expect(throws: JSONParser.Failure.self, "\(bad)") { try JSONParser.parseKeepingNumberText(bytes: Array(bad.utf8)) }
        }
    }
}
