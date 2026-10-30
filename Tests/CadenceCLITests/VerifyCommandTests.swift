import CadenceCore
import Foundation
import Testing

@Suite struct VerifyCommandTests {
    let cli = CLIHome()
    static let proofs = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vectors/proofs")

    @Test func verifyExitCodesAndOutput() throws {
        defer { cli.remove() }
        // The home does not exist: verify must not need or create the store.
        let pass = try cli.run(["verify", Self.proofs.appendingPathComponent("valid.json").path])
        #expect(pass.status == 0)
        #expect(pass.stdout.contains("RESULT  PASS: the chain is complete"))
        #expect(!FileManager.default.fileExists(atPath: cli.database))

        let fail = try cli.run(["verify", Self.proofs.appendingPathComponent("tampered.json").path])
        #expect(fail.status == 2)
        #expect(fail.stdout.contains("RESULT  FAIL"))

        let json = try cli.run(["verify", "--json", Self.proofs.appendingPathComponent("tampered.json").path])
        #expect(json.status == 2)
        #expect(try json.json().objectValue?["passed"] == false)

        let note = try cli.run(["verify", "--recompute", Self.proofs.appendingPathComponent("valid.json").path])
        #expect(note.status == 0)
        #expect(note.stdout.contains("note    "))

        #expect(try cli.run(["verify", "/nonexistent/proof.json"]).status == 4)
        #expect(try cli.run(["verify"]).status == 1)
    }
}
