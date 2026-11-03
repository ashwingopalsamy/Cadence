import Foundation
import Testing

@testable import CadenceCore

@Suite struct CanonicalJSONTests {
    struct Vector: Sendable, CustomTestStringConvertible {
        let name: String
        let input: String
        let canonical: String
        let sha256: String
        var testDescription: String { name }
    }

    static func vectors() throws -> [Vector] {
        let file = try Vectors.json("c14n.json")
        return try #require(file["vectors"]?.arrayValue).map { v in
            Vector(
                name: v["name"]?.stringValue ?? "?", input: v["input"]?.stringValue ?? "",
                canonical: v["canonical"]?.stringValue ?? "", sha256: v["sha256"]?.stringValue ?? "")
        }
    }

    static func rejects() throws -> [(name: String, input: String, stage: String)] {
        let file = try Vectors.json("c14n.json")
        return try #require(file["reject"]?.arrayValue).map { v in
            (v["name"]?.stringValue ?? "?", v["input"]?.stringValue ?? "", v["stage"]?.stringValue ?? "?")
        }
    }

    @Test func vectorFileIsPresent() throws {
        #expect(try Self.vectors().count >= 15)
        #expect(try Self.rejects().count >= 10)
    }

    @Test(arguments: try CanonicalJSONTests.vectors())
    func matchesPythonByteForByte(_ vector: Vector) throws {
        let value = try JSONParser.parse(vector.input)
        let bytes = try CanonicalJSON.bytes(value)
        #expect(bytes == Array(vector.canonical.utf8), "\(vector.name)")
        #expect(SHA256Hasher().sha256Hex(bytes) == vector.sha256)
        // Canonical output is a fixed point.
        #expect(try CanonicalJSON.bytes(JSONParser.parse(bytes: bytes)) == bytes)
    }

    @Test func rejectsEveryRejectVector() throws {
        for reject in try Self.rejects() {
            switch reject.stage {
            case "parse":
                #expect(throws: JSONParser.Failure.self, "\(reject.name)") { try JSONParser.parse(reject.input) }
            case "write":
                let value = try JSONParser.parse(reject.input)
                #expect(throws: CanonicalJSON.Failure.self, "\(reject.name)") { try CanonicalJSON.bytes(value) }
            default:
                Issue.record("unknown stage for \(reject.name)")
            }
        }
    }

    @Test func writerRejectsOutOfRangeIntegersBuiltInCode() {
        #expect(throws: CanonicalJSON.Failure.integerOutOfRange(9_007_199_254_740_992)) {
            try CanonicalJSON.bytes(.int(9_007_199_254_740_992))
        }
        #expect(throws: CanonicalJSON.Failure.integerOutOfRange(Int64.min)) {
            try CanonicalJSON.bytes(.array([.int(Int64.min)]))
        }
    }

    @Test func writerRejectsNonASCIIKeys() {
        #expect(throws: CanonicalJSON.Failure.nonASCIIKey("café")) {
            try CanonicalJSON.bytes(["café": 1])
        }
    }

    @Test func slashIsNeverEscaped() throws {
        #expect(try CanonicalJSON.string("a/b") == "\"a/b\"")
    }

    @Test func combiningSequencesKeepTheirScalars() throws {
        let decomposed = JSONValue.string("e\u{0301}")
        let composed = JSONValue.string("\u{00E9}")
        #expect(try CanonicalJSON.bytes(decomposed) != CanonicalJSON.bytes(composed))
    }

    @Test func parserReportsFloatsAsFloats() {
        #expect(throws: JSONParser.Failure.floatNotAllowed(offset: 5)) {
            try JSONParser.parse("{\"a\":1.5}")
        }
    }

    @Test func parserLimitsDepth() throws {
        let deep = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        #expect(throws: JSONParser.Failure.tooDeep) { try JSONParser.parse(deep) }
        let limit = JSONParser.maxDepth
        _ = try JSONParser.parse(String(repeating: "[", count: limit) + String(repeating: "]", count: limit))
        #expect(throws: JSONParser.Failure.tooDeep) {
            try JSONParser.parse(String(repeating: "[", count: limit + 1) + String(repeating: "]", count: limit + 1))
        }
    }

    @Test func writerLimitsDepthLikeTheParser() throws {
        func nested(_ n: Int) -> JSONValue { n == 0 ? .int(1) : .array([nested(n - 1)]) }
        let ok = try CanonicalJSON.bytes(nested(JSONParser.maxDepth))
        _ = try JSONParser.parse(bytes: ok)
        #expect(throws: CanonicalJSON.Failure.tooDeep) { try CanonicalJSON.bytes(nested(JSONParser.maxDepth + 1)) }
    }

    @Test func equalityFollowsTheBytes() {
        #expect(JSONValue.string("\u{00E9}") != JSONValue.string("e\u{0301}"))
        #expect(Set<JSONValue>([.string("\u{00E9}"), .string("e\u{0301}")]).count == 2)
        let a: JSONValue = ["a": [1, "x"]]
        let b: JSONValue = ["a": [1, "x"]]
        #expect(a == b)
    }

    @Test func parserRejectsInvalidUTF8() {
        #expect(throws: JSONParser.Failure.invalidUTF8) { try JSONParser.parse(bytes: [0x22, 0xC3, 0x28, 0x22]) }
    }
}
