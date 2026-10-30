import ArgumentParser
import CadenceCore
import Foundation

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check a proof file: the chain, then every day against the events it cites (docs/SPEC.md section 12.3).",
        discussion: """
            Prints the same lines as tools/verify_proof.py. It never opens the store.
            --recompute adds note lines after them, without changing PASS or FAIL: the count of in-range \
            events that are hash-only, so their payloads cannot be checked.
            Exit codes: 0 pass, 2 fail, 1 usage, 4 file not found.
            """)

    @Argument(help: "The proof file.") var file: String
    @Flag(name: .long, help: "Add notes about what could not be recomputed from the file alone.") var recompute = false
    @Flag(name: .long, help: "Print {passed, fails, warns} as one JSON object.") var json = false

    func run() throws {
        guard let data = FileManager.default.contents(atPath: file) else {
            throw fail(.notFound("no such file: \(file)"))
        }
        let report = ProofVerifier.verify(bytes: Array(data), recompute: recompute)
        if json {
            let value: JSONValue = [
                "passed": .bool(report.passed), "fails": .array(report.fails.map { .string($0) }),
                "warns": .array(report.warns.map { .string($0) }),
            ]
            do { writeLine(try CanonicalJSON.string(value), to: FileHandle.standardOutput) } catch {
                throw fail(.io("cannot encode the result as JSON"))
            }
        } else {
            writeLine(report.lines.joined(separator: "\n"), to: FileHandle.standardOutput)
        }
        if !report.passed { throw ExitCode(CadenceError.validation("").exitCode) }
    }
}
