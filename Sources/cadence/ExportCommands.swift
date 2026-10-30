import ArgumentParser
import CadenceCore
import Foundation

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Export the log.", subcommands: [ExportProof.self])
}

struct ExportProof: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proof",
        abstract: "Write a proof file: the hash chain, the days and its own verifier (docs/SPEC.md section 12).",
        discussion: "Without -o the file goes to the exports folder. Use -o - for standard output.")

    @OptionGroup var output: OutputOptions
    @Option(help: "First day, YYYY-MM-DD.") var from: String
    @Option(help: "Last day, YYYY-MM-DD.") var to: String
    @Option(name: [.customShort("o"), .long], help: "Where to write the file, or - for standard output.") var out: String?

    func run() throws {
        try output.run { context in
            let from = try Args.required(self.from, option: "from")
            let to = try Args.required(self.to, option: "to")
            guard from <= to else { throw CadenceError.validation("--from: \(from) is after --to \(to)") }
            let journal = try context.openJournal()
            guard to <= journal.today() else { throw CadenceError.validation("--to: \(to) is in the future") }
            let profile = journal.config.profile
            let request = ProofRequest(
                from: from, to: to, zone: profile.timezone, name: profile.name, role: profile.role,
                rules: DayRules(config: journal.config), generatedAt: context.clock.now())
            let proof = try ProofExporter.export(journal.store, request)
            if out == "-" {
                FileHandle.standardOutput.write(Data(proof.bytes))
                return Rendered(human: "", json: .null, streamed: true)
            }
            let url = out.map { URL(fileURLWithPath: $0) }
                ?? context.roots.exports.appendingPathComponent("\(from)_\(to).cadence-proof.json")
            try PrivateFile.save(proof.bytes, to: url)
            let human = [
                "Wrote \(url.path)",
                "\(from) to \(to): \(proof.events) events, \(proof.items) items, \(proof.witnesses) witness codes",
                proof.privateEvents > 0 ? "\(proof.privateEvents) private events in range are exported as hashes only" : nil,
                "The file carries its own verifier; how_to_verify inside it explains the checks",
            ].compactMap { $0 }.joined(separator: "\n")
            let json: JSONValue = [
                "path": .string(url.path), "from": .string(from.description), "to": .string(to.description),
                "events": .int(Int64(proof.events)), "items": .int(Int64(proof.items)),
                "private_events": .int(Int64(proof.privateEvents)), "witnesses": .int(Int64(proof.witnesses)),
                "export_digest": .string(proof.exportDigest),
            ]
            return Rendered(human: human, json: json)
        }
    }
}
