import Foundation
import Testing

@testable import CadenceCore

/// The settings files Cadence edits belong to the user, so the reader keeps member order and number text, and the
/// writer matches what Claude Code itself writes: two-space indent, one member per line.
@Suite struct OrderedJSONTests {
    static func parse(_ text: String) throws(CadenceError) -> OrderedJSON {
        try OrderedJSON.parse(Array(text.utf8))
    }

    @Test func roundTripKeepsMemberOrderAndNumberText() throws {
        let text = """
            {
              "zeta": 1.50,
              "alpha": [
                1e3,
                -0,
                true,
                null,
                "x"
              ],
              "mid": {
                "b": 2,
                "a": 1
              },
              "empty": {},
              "none": []
            }
            """
        let value = try Self.parse(text)
        #expect(value.serialized() == text)
        #expect(value.members?.map(\.key) == ["zeta", "alpha", "mid", "empty", "none"])
    }

    @Test func formatsNestedValuesWithTwoSpaces() throws {
        let value = try Self.parse(#"{"a":{"b":[{"c":1},2]},"d":"e"}"#)
        let expected = """
            {
              "a": {
                "b": [
                  {
                    "c": 1
                  },
                  2
                ]
              },
              "d": "e"
            }
            """
        #expect(value.serialized() == expected)
    }

    @Test func stringsEscapeAndUnescape() throws {
        let value = try Self.parse(#"{"k":"café \"q\" \\ \n \t \u0001 😀 /"}"#)
        #expect(value["k"]?.stringValue == "caf\u{E9} \"q\" \\ \n \t \u{1} \u{1F600} /")
        let out = value.serialized()
        // Non-ASCII stays as typed, control characters are escaped, the slash is not.
        #expect(out.contains("caf\u{E9}"))
        #expect(out.contains(#"\u0001"#))
        #expect(out.contains(#"\n"#))
        #expect(!out.contains(#"\/"#))
        #expect(try Self.parse(out) == value)
    }

    @Test func rejectsWhatIsNotStrictJSON() {
        let bad = [
            "", "   ", "{", "[1,]", #"{"a":1,}"#, #"{"a" 1}"#, "{'a':1}", #"{"a":1} x"#, "// note\n{}", "{/* c */}",
            #"{"a":01}"#, #"{"a":1.}"#, #"{"a":.5}"#, #"{"a":+1}"#, #"{"a":NaN}"#, #""\ud800""#, #""\x41""#, "\"a\nb\"",
            #"{"a":tru}"#,
        ]
        for text in bad {
            #expect(throws: CadenceError.self, "\(text)") { try Self.parse(text) }
        }
    }

    @Test func errorsNameTheLine() {
        do {
            _ = try Self.parse("{\n  \"a\": 1,\n  oops\n}")
            Issue.record("expected a parse error")
        } catch {
            #expect(error.message.contains("line 3"))
            #expect(error.message.hasPrefix("not valid JSON"))
        }
    }

    @Test func refusesAbsurdNesting() {
        let deep = String(repeating: "[", count: 1000) + String(repeating: "]", count: 1000)
        #expect(throws: CadenceError.self) { try Self.parse(deep) }
    }

    @Test func duplicateKeysAreKeptAndTheLastOneWins() throws {
        let value = try Self.parse(#"{"a":1,"b":2,"a":3}"#)
        #expect(value["a"] == .number("3"))
        #expect(value.members?.count == 3)
        #expect(value.serialized().components(separatedBy: "\"a\"").count == 3)
    }

    @Test func settingAMemberKeepsItsPlaceOrAppends() throws {
        var value = try Self.parse(#"{"a":1,"b":2,"c":3}"#)
        let replaced = value.setMember("b", .string("two"))
        let appended = value.setMember("d", .bool(true))
        #expect(replaced && appended)
        #expect(value.members?.map(\.key) == ["a", "b", "c", "d"])
        #expect(value["b"] == .string("two"))
        var notAnObject = OrderedJSON.array([])
        let refused = notAnObject.setMember("x", .null)
        #expect(!refused)
        #expect(notAnObject == .array([]))
    }

    @Test func numbersReadAsDoublesOnlyWhenTheyAreNumbers() throws {
        #expect(try Self.parse("400").doubleValue == 400)
        #expect(try Self.parse("4e2").doubleValue == 400)
        #expect(try Self.parse(#""400""#).doubleValue == nil)
        #expect(OrderedJSON.null.doubleValue == nil)
    }
}
