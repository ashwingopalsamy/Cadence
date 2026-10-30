import Foundation
import Testing

@testable import CadenceCore

/// The Swift verifier must print what `tools/verify_proof.py` prints and reach the same verdict.
/// Two documented differences: the text after "the file is not a readable proof:" is the Swift cause, and
/// the Swift parser refuses floats (cadence-c14n/1) where Python accepts them.
@Suite struct ProofVerifierTests {
    static let unreadable = "FAIL    the file is not a readable proof:"

    static func normalised(_ lines: [String]) -> [String] {
        lines.map { $0.hasPrefix(unreadable) ? unreadable : $0 }
    }

    /// Runs both verifiers on `bytes` and checks that they agree. Returns the Swift report.
    @discardableResult
    static func agree(_ bytes: [UInt8], _ label: String) throws -> ProofReport {
        let python = try ProofExportTests.python(try ProofExportTests.write(bytes))
        let pythonLines = python.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let swift = ProofVerifier.verify(bytes: bytes)
        #expect(normalised(swift.lines) == normalised(pythonLines), "\(label)\nswift:\n\(swift.lines.joined(separator: "\n"))\npython:\n\(python.output)")
        #expect(swift.passed == (python.status == 0), "\(label): verdict")
        return swift
    }

    @Test func everyVectorMatchesPython() throws {
        let dir = Vectors.root.appendingPathComponent("proofs")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
        #expect(files.count >= 20)
        for name in files {
            let bytes = Array(try Data(contentsOf: dir.appendingPathComponent(name)))
            let report = try Self.agree(bytes, name)
            #expect(report.passed == name.hasPrefix("valid"), "\(name)")
        }
    }

    @Test func aFreshExportPassesAndMatchesPython() throws {
        let (store, clock) = try ProofExportTests.october()
        let proof = try ProofExporter.export(store, ProofExportTests.request(clock))
        let report = try Self.agree(proof.bytes, "export")
        #expect(report.passed)
        #expect(report.lines.last == "RESULT  PASS: the chain is complete and in order, and every item, seal and witness matches it")

        let text = String(decoding: proof.bytes, as: UTF8.self)
        let edited = text.replacingOccurrences(of: "\"title\":\"Paired on the flaky test\"", with: "\"title\":\"Paired on the flaky tests\"")
        #expect(edited != text)
        let failed = try Self.agree(Array(edited.utf8), "edited export")
        #expect(!failed.passed)
        #expect(failed.fails.first == "export_digest does not match the file: it was edited after export")
    }

    @Test func brokenFilesFailTheSameWay() throws {
        let cases: [(String, String)] = [
            ("null", "null"),
            ("array", "[]"),
            ("string", "\"cadence.proof/1\""),
            ("empty object", "{}"),
            ("odd format", "{\"format\":[1,true,null,\"it's\"]}"),
            ("truncated", "{\"format\":"),
            ("not json", "hello"),
            ("no chain", "{\"format\":\"cadence.proof/1\"}"),
            ("no days", "{\"format\":\"cadence.proof/1\",\"chain\":{\"events\":[]},\"range\":{\"from\":\"2026-10-27\",\"to\":\"2026-10-30\",\"tz\":\"UTC\"}}"),
            ("empty chain and days", "{\"format\":\"cadence.proof/1\",\"chain\":{\"events\":[]},\"days\":[],\"range\":{\"from\":\"2026-10-27\",\"to\":\"2026-10-30\",\"tz\":\"UTC\"}}"),
            ("events not a list", "{\"format\":\"cadence.proof/1\",\"chain\":{\"events\":7},\"days\":[],\"range\":{}}"),
        ]
        for (label, text) in cases {
            let report = try Self.agree(Array(text.utf8), label)
            #expect(!report.passed, "\(label)")
        }
    }

    @Test func aFloatIsRefusedHerePythonAcceptsIt() throws {
        let valid = Array(try Data(contentsOf: Vectors.root.appendingPathComponent("proofs/valid.json")))
        let text = String(decoding: valid, as: UTF8.self)
        let withFloat = "{\"extra\":1.5," + text.dropFirst()
        let swift = ProofVerifier.verify(bytes: Array(withFloat.utf8))
        let python = try ProofExportTests.python(try ProofExportTests.write(Array(withFloat.utf8)))
        #expect(!swift.passed)
        #expect(swift.lines.first?.hasPrefix(Self.unreadable) == true)
        // Python reads the file; it fails only because the extra key changes the export digest.
        #expect(!python.output.contains("not a readable proof"))
        #expect(python.output.contains("export_digest does not match"))
    }

    @Test func recomputeAddsANoteAndNeverChangesTheVerdict() throws {
        let (store, clock) = try ProofExportTests.october()
        let proof = try ProofExporter.export(store, ProofExportTests.request(clock))
        let plain = ProofVerifier.verify(bytes: proof.bytes)
        let more = ProofVerifier.verify(bytes: proof.bytes, recompute: true)
        #expect(more.passed == plain.passed)
        #expect(Array(more.lines.prefix(plain.lines.count)) == plain.lines)
        #expect(more.lines.count == plain.lines.count + 1)
        #expect(more.lines.last?.hasPrefix("note    ") == true)
        #expect(more.lines.last?.contains(" in-range events are hash-only") == true)

        let bad = ProofVerifier.verify(bytes: Array("null".utf8), recompute: true)
        #expect(!bad.passed)
        #expect(bad.lines.count == 2)
    }
}
