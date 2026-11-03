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

    // MARK: - Audit fixes

    /// The message of the error `body` throws, or nil when it does not throw.
    static func failure(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as CadenceError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    static let itemMap = """
        {"cadence":"map/1","input":"json","produces":"item","records":"$[*]",
         "fields":{"kind":{"const":"oncall.shift"},"title":{"path":"$.t"},"ticket":{"path":"$.k"},"day":{"path":"$.d","default":"2026-10-28"}},
         "source_ref":"%@"}
        """

    static func itemRefs(_ template: String, _ input: String) throws -> [String?] {
        try records(itemMap.replacingOccurrences(of: "%@", with: template), input).records.map { $0["source_ref"]?.stringValue }
    }

    @Test func moreThan20000JSONRecordsAreRefusedBeforeAnyIsMapped() throws {
        let input = Array((#"{"data":["# + String(repeating: "{},", count: 100_000) + #"{}]}"#).utf8)
        let engine = try Self.engine(Self.endpointMap)
        // The records are counted after the path selects them and before one is mapped.
        #expect(Self.failure { _ = try engine.records(from: input) } == "map test: more than 20,000 records")
        let start = ContinuousClock.now
        let message = Self.failure {
            _ = try engine.envelope(from: input, collector: "endpoint", window: Self.window, run: "r1", generatedAt: Self.generatedAt)
        }
        #expect(message == "map test: more than 20,000 records")
        #expect(ContinuousClock.now - start < .seconds(2))
        // Exactly the cap is fine.
        let ok = Array((#"{"data":["# + String(repeating: "{},", count: 19_999) + #"{}]}"#).utf8)
        #expect(Self.failure { _ = try engine.records(from: ok) } == nil)
    }

    @Test func csvStopsReadingPastTheRecordCap() throws {
        let csv = "a,b\n" + String(repeating: "1,2\n", count: 100_000)
        // One more than the cap is enough to tell, so the rest is never read.
        #expect(try CSVReader.rows(Array(csv.utf8)).count == EnvelopeReader.maxRecords + 1)
        let map = Self.endpointMap.replacingOccurrences(of: #""input": "json""#, with: #""input": "csv""#)
            .replacingOccurrences(of: #""records": "$.data[*]","#, with: "")
        let start = ContinuousClock.now
        let message = Self.failure {
            _ = try Self.engine(map).envelope(
                from: Array(csv.utf8), collector: "endpoint", window: Self.window, run: "r1", generatedAt: Self.generatedAt)
        }
        #expect(message == "map test: more than 20,000 records")
        #expect(ContinuousClock.now - start < .seconds(2))
        let exact = "a,b\n" + String(repeating: "1,2\n", count: EnvelopeReader.maxRecords)
        #expect(try CSVReader.rows(Array(exact.utf8)).count == EnvelopeReader.maxRecords)
    }

    @Test func oneHugeCSVRowCannotAllocateMillionsOfColumns() throws {
        let wideHeader = (0..<300).map { "c\($0)" }.joined(separator: ",")
        #expect(Self.failure { _ = try CSVReader.rows(Array((wideHeader + "\n1\n").utf8)) } == "the CSV has more than 256 columns")
        let csv = "a,b\n" + String(repeating: ",", count: 1_000_000) + "\n1,2\n"
        let start = ContinuousClock.now
        let rows = try CSVReader.rows(Array(csv.utf8))
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(rows.count == 2)
        guard case .failure(let error) = rows[0].value else { Issue.record("expected the wide row to fail"); return }
        #expect(error.message == "has 1000001 columns, the header has 2")
        guard case .success = rows[1].value else { Issue.record("expected the next row to read"); return }
    }

    @Test func sourceRefIsBuiltInOnePassAndSubstitutedValuesAreEncoded() throws {
        // A value that looks like a placeholder is data, never expanded again.
        let first = try Self.itemRefs("{title}-{day}", #"[{"t":"{day}","d":"2026-10-28"}]"#)
        #expect(first == ["%7Bday%7D-2026-10-28"])
        // Colons in values cannot move a boundary, so these two records stay two records.
        let pairs = try Self.itemRefs("x:{title}:{ticket}", #"[{"t":"x:y","k":"z"},{"t":"x","k":"y:z"}]"#)
        #expect(pairs == ["x:x%3Ay:z", "x:x:y%3Az"])
        #expect(Set(pairs.compactMap { $0 }).count == 2)
        // The escape itself is escaped, so a literal %3A cannot stand in for a colon.
        let escapes = try Self.itemRefs("{title}", #"[{"t":"a%3Ab"},{"t":"a:b"},{"t":"{}"}]"#)
        #expect(escapes == ["a%253Ab", "a%3Ab", "%7B%7D"])
    }

    @Test func aNegativeValueIsRefusedBeforeItIsRounded() throws {
        for text in ["-0.0000004", "-0.0000005", "-0.1", "-1", " -2.5"] {
            for json in [#""\#(text)""#, text.trimmingCharacters(in: .whitespaces)] {
                let (records, skipped) = try Self.records(Self.endpointMap, #"{"data":[{"date":"2026-10-28","output_tokens":1,"cost_usd":\#(json)}]}"#)
                #expect(records.isEmpty && skipped == ["record 1: cost_micros: must not be negative"], "\(json): \(skipped)")
            }
        }
        // Zero is zero, whatever sign it carries.
        for text in ["-0", "-0.0", "-0.0000000", "-0e5"] {
            let (records, skipped) = try Self.records(Self.endpointMap, #"{"data":[{"date":"2026-10-28","output_tokens":1,"cost_usd":"\#(text)"}]}"#)
            #expect(skipped.isEmpty && records.first?["cost_micros"] == 0, "\(text): \(skipped)")
        }
        #expect(!Decimal10.isNegative("-0.000") && !Decimal10.isNegative("-0e9"))
        #expect(Decimal10.isNegative("-0.0000004") && Decimal10.isNegative(" -1e-9"))
        #expect(!Decimal10.isNegative("0.5") && !Decimal10.isNegative("+0.5") && !Decimal10.isNegative("1e-3"))
    }

    @Test func constsAndDefaultsAreConvertedWhenTheMapIsLoaded() throws {
        let tool = #""tool":               { "const": "claude-code" },"#
        let cacheRead = #""tokens.cache_read":  { "path": "$.cache_read_tokens", "default": 0 },"#
        let cases: [(String, String)] = [
            (tool, #""tool": { "const": "claude-code" }, "sessions": { "const": "lots" },"#),
            (tool, #""tool": { "const": "claude-code" }, "sessions": { "const": -3 },"#),
            (tool, #""tool": { "const": "claude-code" }, "estimated": { "const": "maybe" },"#),
            (tool, #""tool": { "const": "claude-code" }, "estimated": { "const": 1 },"#),
            (#""day":                { "path": "$.date", "format": "yyyy-MM-dd" },"#, #""day": { "path": "$.date", "default": "yesterday" },"#),
            (cacheRead, #""tokens.cache_read": { "path": "$.c", "default": "many" },"#),
            (cacheRead, #""tokens.cache_read": { "path": "$.c", "default": [1] },"#),
            (#""model":              { "path": "$.model", "default": "*" },"#, #""model": { "path": "$.model", "default": {"a": 1} },"#),
        ]
        for (old, new) in cases {
            let text = Self.endpointMap.replacingOccurrences(of: old, with: new)
            #expect(text != Self.endpointMap, "\(old)")
            #expect(throws: CadenceError.self, "\(new)") { try MapFile(bytes: Array(text.utf8), name: "bad") }
        }
        // The message says which rule failed and why.
        let bad = Self.endpointMap.replacingOccurrences(of: tool, with: #""tool": { "const": "claude-code" }, "sessions": { "const": "lots" },"#)
        #expect(Self.failure { _ = try MapFile(bytes: Array(bad.utf8), name: "bad") }
            == "map bad.fields.sessions.const: sessions: 'lots' is not a whole number")
        let badDefault = Self.endpointMap.replacingOccurrences(of: cacheRead, with: #""tokens.cache_read": { "path": "$.c", "default": "many" },"#)
        #expect(Self.failure { _ = try MapFile(bytes: Array(badDefault.utf8), name: "bad") }
            == "map bad.fields.tokens.cache_read.default: tokens.cache_read: 'many' is not a whole number")
        // Good ones still load: a text integer, a padded boolean, a scaled decimal default, a time.
        let good = Self.endpointMap.replacingOccurrences(
            of: tool, with: #""tool": { "const": "claude-code" }, "sessions": { "const": "7" }, "estimated": { "const": " TRUE " },"#
        ).replacingOccurrences(of: #""scale": 1000000"#, with: #""scale": 1000000, "default": "0.5""#)
        _ = try MapFile(bytes: Array(good.utf8), name: "good")
        let timed = Self.itemMap.replacingOccurrences(of: "%@", with: "x:{title}")
            .replacingOccurrences(of: #""kind":{"const":"oncall.shift"},"#, with: #""kind":{"const":"oncall.shift"},"occurred_at":{"const":"2026-10-28T10:30:00Z"},"#)
        _ = try MapFile(bytes: Array(timed.utf8), name: "timed")
        let badTime = timed.replacingOccurrences(of: "2026-10-28T10:30:00Z", with: "10:30")
        #expect(throws: CadenceError.self) { try MapFile(bytes: Array(badTime.utf8), name: "bad") }
    }

    @Test func attrsKeysFollowTheEnvelopeRuleWhenTheMapIsLoaded() throws {
        func map(_ key: String) -> [UInt8] {
            Array(Self.itemMap.replacingOccurrences(of: "%@", with: "x:{title}")
                .replacingOccurrences(of: #""kind":{"const":"oncall.shift"},"#, with: #""kind":{"const":"oncall.shift"},"\#(key)":{"path":"$.n"},"#).utf8)
        }
        _ = try MapFile(bytes: map("attrs.\(String(repeating: "k", count: 64))"), name: "ok")
        _ = try MapFile(bytes: map("attrs.a b"), name: "ok")
        for key in ["attrs.\(String(repeating: "k", count: 65))", #"attrs.a\u0001b"#, #"attrs.\u007f"#, "attrs.", "attrs.a.b"] {
            #expect(throws: CadenceError.self, "\(key)") { try MapFile(bytes: map(key), name: "bad") }
        }
        let long = Self.failure { _ = try MapFile(bytes: map("attrs.\(String(repeating: "k", count: 65))"), name: "bad") }
        #expect(long?.contains("must be 1 to 64 characters") == true, "\(long ?? "")")
        // A control character never reaches the message.
        let control = Self.failure { _ = try MapFile(bytes: map(#"attrs.a\u0001b"#), name: "bad") }
        #expect(control != nil && control?.unicodeScalars.contains(where: { $0.value < 0x20 }) == false)
    }

    @Test func epochTimesStopAtYear9999() throws {
        let map = """
            {"cadence":"map/1","input":"json","produces":"item","records":"$[*]",
             "fields":{"kind":{"const":"oncall.shift"},"title":{"path":"$.t"},"occurred_at":{"path":"$.at","format":"%@"}},
             "source_ref":"x:{title}"}
            """
        func run(_ format: String, _ value: String) throws -> (JSONValue?, [String]) {
            let (records, skipped) = try Self.records(map.replacingOccurrences(of: "%@", with: format), #"[{"t":"Shift","at":\#(value)}]"#)
            return (records.first?["occurred_at"], skipped)
        }
        #expect(try run("epoch-s", "253402214400").0 == "9999-12-31T05:30:00+05:30")
        #expect(try run("epoch-s", "253402300800").1 == ["record 1: occurred_at: '253402300800' is not an epoch time"])
        #expect(try run("epoch-s", "99999999999999").1.count == 1)
        #expect(try run("epoch-ms", "253402214400000").0 == "9999-12-31T05:30:00+05:30")
        #expect(try run("epoch-ms", "253402300800000").1 == ["record 1: occurred_at: '253402300800000' is not an epoch time"])
        // A time in milliseconds read as seconds is far past 9999 and no longer slips through.
        #expect(try run("epoch-s", "1793183400000").1.count == 1)
    }

    @Test func whitespaceOnlyValuesCountAsMissingAndBooleansAreTrimmed() throws {
        let (records, skipped) = try Self.records(Self.endpointMap, """
            {"data":[{"date":"2026-10-28","model":" \\t ","output_tokens":1},{"date":"2026-10-28","model":"\\n","output_tokens":2},
                     {"date":"2026-10-28","model":"","output_tokens":3},{"date":"2026-10-28","model":null,"output_tokens":4}]}
            """)
        #expect(skipped.isEmpty && records.map { $0["model"] } == ["*", "*", "*", "*"], "\(skipped)")
        // Without a default a blank value is missing, as an empty one is.
        let noDefault = Self.endpointMap.replacingOccurrences(of: #""model":              { "path": "$.model", "default": "*" },"#, with: #""model": { "path": "$.model" },"#)
        let (none, why) = try Self.records(noDefault, #"{"data":[{"date":"2026-10-28","model":"   "}]}"#)
        #expect(none.isEmpty && why == ["record 1: source_ref: {model} has no value"], "\(why)")

        let withFlag = Self.endpointMap.replacingOccurrences(
            of: #""tool":               { "const": "claude-code" },"#, with: #""tool": { "const": "claude-code" }, "estimated": { "path": "$.est" },"#)
        let flags = try Self.records(withFlag, """
            {"data":[{"date":"2026-10-28","est":" true "},{"date":"2026-10-28","model":"b","est":"FALSE\\n"},{"date":"2026-10-28","model":"c","est":" maybe "}]}
            """)
        #expect(flags.records.map { $0["estimated"] } == [true, false])
        #expect(flags.skipped == ["record 3: estimated: is not true or false"])
    }

    @Test func aScaleOfOneIsRefusedAndLeftOutMeansExact() throws {
        let one = Self.endpointMap.replacingOccurrences(of: #""scale": 1000000"#, with: #""scale": 1"#)
        #expect(Self.failure { _ = try MapFile(bytes: Array(one.utf8), name: "bad") }
            == "map bad.fields.cost_micros.scale: scale must be 10 or more; leave it out for exact values")
        let ten = Self.endpointMap.replacingOccurrences(of: #""scale": 1000000"#, with: #""scale": 10"#)
        _ = try MapFile(bytes: Array(ten.utf8), name: "ok")
        for bad in ["0", "250", "10000000000000"] {
            let text = Self.endpointMap.replacingOccurrences(of: #""scale": 1000000"#, with: #""scale": \#(bad)"#)
            let message = Self.failure { _ = try MapFile(bytes: Array(text.utf8), name: "bad") }
            #expect(message == "map bad.fields.cost_micros.scale: must be 10, 100 and so on up to 10^12", "\(bad): \(message ?? "")")
        }
    }

    @Test func pathIndexesRefuseLeadingZeros() throws {
        for bad in ["$[01]", "$[00]", "$.a[007]"] {
            #expect(throws: CadenceError.self, "\(bad)") { try MapPath(bad) }
        }
        let doc = try JSONParser.parse(#"{"a":[0,1,2,3,4,5,6,7,8,9,10]}"#)
        #expect(try MapPath("$.a[0]").select(doc) == [0])
        #expect(try MapPath("$.a[10]").select(doc) == [10])
    }

    @Test func aMapFileOver256KBIsRefused() throws {
        let padding = String(repeating: " ", count: MapFile.maxBytes - Self.endpointMap.utf8.count)
        _ = try MapFile(bytes: Array((Self.endpointMap + padding).utf8), name: "ok")
        #expect(Self.failure { _ = try MapFile(bytes: Array((Self.endpointMap + padding + " ").utf8), name: "big") }
            == "map big: the file is larger than 256 KB")
    }

    @Test func csvCountsALoneCarriageReturnAsALineBreak() throws {
        let map = Self.endpointMap.replacingOccurrences(of: #""input": "json""#, with: #""input": "csv""#)
            .replacingOccurrences(of: #""records": "$.data[*]","#, with: "")
        // Line 1 is the header, line 2 starts the quoted field, line 3 ends it, so the bad row is on line 4.
        let csv = "date,model,request_count,input_tokens,output_tokens,cost_usd\r"
            + "2026-10-27,\"a\rb\",1,1,1,1\r"
            + "2026-10-28,m,oops,1,1,1\r"
        let (records, skipped) = try Self.records(map, csv)
        #expect(records.count == 1 && records[0]["model"] == "a\rb")
        #expect(skipped == ["row at line 4: requests: 'oops' is not a whole number"])
        // CRLF inside quotes is still one break.
        let crlf = "a,b\r\n\"x\r\ny\",1\r\n2,3,4\r\n"
        let rows = try CSVReader.rows(Array(crlf.utf8))
        #expect(rows.map(\.line) == [2, 4])
    }

    @Test func csvRefusesQuotesThatAreNotRFC4180() throws {
        let cases: [(String, String)] = [
            ("a,b\n1,x\"y\n", "the CSV is malformed at line 2: a quote inside an unquoted field"),
            ("a,b\n1,2\n3, \"y\"\n", "the CSV is malformed at line 3: a quote inside an unquoted field"),
            ("a,b\n1,\"y\"z\n", "the CSV is malformed at line 2: text after a closing quote"),
            ("a,b\n1,\"y\" \n", "the CSV is malformed at line 2: text after a closing quote"),
            ("a,b\n1,2\n\"x\ny\"\"z\",\"q\"r\n", "the CSV is malformed at line 4: text after a closing quote"),
            ("a\"b,c\n1,2\n", "the CSV is malformed at line 1: a quote inside an unquoted field"),
        ]
        for (csv, expected) in cases {
            #expect(Self.failure { _ = try CSVReader.rows(Array(csv.utf8)) } == expected, "\(csv)")
        }
        // Proper quoting is untouched: doubled quotes, commas, line breaks and an empty quoted field.
        let fine = "a,b\n\"x\"\"y\",\"p,q\"\n\"\",\"line\nbreak\"\n\"last\",\"end\""
        let rows = try CSVReader.rows(Array(fine.utf8))
        #expect(rows.count == 3)
        guard case .success(let first) = rows[0].value, case .success(let second) = rows[1].value else { Issue.record("rows"); return }
        #expect(first["a"] == "x\"y" && first["b"] == "p,q" && second["a"] == "" && second["b"] == "line\nbreak")
    }
}
