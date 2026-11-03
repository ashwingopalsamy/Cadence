import CadenceCore
import Foundation
import Testing

@Suite struct ExportTests {
    let cli = CLIHome()

    static let verifier = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/verify_proof.py")

    func python(_ path: String) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", Self.verifier.path, path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func exportProofWritesAPrivateFileThePythonVerifierPasses() throws {
        defer { cli.remove() }
        let today = try cli.today()
        _ = try cli.run(["log", "Merged ACME-482913 retry budget"])
        _ = try cli.run(["log", "Private thought", "--kind", "note"])
        let result = try cli.json(["export", "proof", "--from", today.adding(days: -3).description, "--to", today.description])
        let path = try #require(result["path"]?.stringValue)
        #expect(path.hasPrefix(cli.home.appendingPathComponent("exports").path))
        #expect(result["private_events"]?.intValue == 1)  // the note defaults to digest
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let (status, output) = try python(path)
        #expect(status == 0, "\(output)")
        #expect(output.contains("RESULT  PASS"))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!text.contains("Private thought"))
    }

    @Test func exportProofToStdoutAndToAChosenFile() throws {
        defer { cli.remove() }
        let today = try cli.today()
        _ = try cli.run(["log", "Reviewed the settlement RFC"])
        let stdout = try cli.run(["export", "proof", "--from", today.description, "--to", today.description, "-o", "-"])
        #expect(stdout.status == 0)
        let parsed = try JSONParser.parse(stdout.stdout.trimmingCharacters(in: .newlines))
        #expect(parsed["format"]?.stringValue == "cadence.proof/1")
        let file = cli.home.appendingPathComponent("chosen.json").path
        let human = try cli.run(["export", "proof", "--from", today.description, "--to", today.description, "-o", file])
        #expect(human.status == 0)
        #expect(human.stdout.contains("Wrote \(file)"))
        #expect(try python(file).0 == 0)
    }

    @Test func exportProofRefusesBadRanges() throws {
        defer { cli.remove() }
        let today = try cli.today()
        #expect(try cli.run(["export", "proof", "--from", "2026-13-01", "--to", today.description]).status == 2)
        #expect(try cli.run(["export", "proof", "--from", today.description, "--to", today.adding(days: -1).description]).status == 2)
        #expect(try cli.run(["export", "proof", "--from", today.description, "--to", today.adding(days: 1).description]).status == 2)
        #expect(try cli.run(["export", "proof", "--to", today.description]).status == 1)
    }
}
