import ArgumentParser
import CadenceCore
import Foundation

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import", abstract: "Import a file through a map.", subcommands: [ImportGenAICommand.self])
}

struct ImportGenAICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "genai",
        abstract: "Import GenAI usage from a CSV or JSON file through a map/1 file.",
        discussion: """
            Rows are recorded with source import:NAME. The file is read once and not kept. Use --dry-run first: it \
            writes nothing and shows one line per day beside what other sources already say. No network is used.
            """)

    @Argument(help: "The export to read (CSV or JSON, at most 10 MB).") var file: String
    @Option(name: .long, help: "The map/1 file that describes the export.") var map: String
    @Flag(name: .customLong("dry-run"), help: "Show the per-day table and write nothing.") var dryRun = false
    @Option(name: .long, help: "Import name. Default: the map file name without .json.") var name: String?
    @OptionGroup var output: OutputOptions

    func run() throws {
        try output.run { context in
            let config = try context.loadConfig().config
            guard let zone = TimeZone(identifier: config.profile.timezone) else {
                throw CadenceError.validation("profile.timezone: '\(config.profile.timezone)' is not a time zone")
            }
            let mapURL = URL(fileURLWithPath: map)
            let importName = name ?? mapURL.deletingPathExtension().lastPathComponent
            guard Actor.isValidName(importName) else {
                throw CadenceError.validation("name: '\(importName)' must be 1 to 64 lowercase letters, digits or -; pass --name")
            }
            let mapBytes = try Self.read(map, what: "the map", limit: 1024 * 1024)
            let data = try Self.read(file, what: "the file", limit: 10 * 1024 * 1024)
            let mapFile = try MapFile(bytes: mapBytes, name: importName)
            guard mapFile.produces == "genai.usage" else {
                throw CadenceError.validation("map \(importName): produces '\(mapFile.produces)'; an import needs genai.usage")
            }
            let engine = MapEngine(map: mapFile, zone: zone, boundary: config.dayBoundary)
            let runID = ULIDGenerator(clock: context.clock, random: SystemRandomSource()).next()
            let now = context.clock.now()
            let today = config.dayBoundary.day(of: now, in: zone)
            let probe = IngestWindow(since: today.description, until: today.description)
            let first = try engine.envelope(from: data, collector: importName, window: probe, run: runID, generatedAt: now)
            let source = "import:\(importName)"
            let plain = GenAIImportPreview(map: mapFile, output: first, existing: [], ownSource: source, declared: { _ in nil })
            guard let low = plain.days.map(\.day).min(), let high = plain.days.map(\.day).max() else {
                throw CadenceError.validation(
                    "no usage rows could be read from \(file)" + (first.skipped.isEmpty ? "" : "; first problem: \(first.skipped[0])"))
            }
            let window = IngestWindow(since: low.description, until: high.description)

            if dryRun {
                var existing: [GenAISourceDay] = []
                var declared: [LocalDate: DayKind] = [:]
                // A dry run never creates the ledger: with none yet there is nothing to compare with.
                if FileManager.default.fileExists(atPath: context.roots.database.path) {
                    let store = try context.openStore()
                    if try store.eventCount() > 0 {
                        let journal = try context.openJournal()
                        existing = try journal.genaiSourceDays(from: low, to: high)
                        for day in Set(plain.days.map(\.day)) {
                            if let kind = try store.declaredKind(of: day) { declared[day] = kind }
                        }
                    }
                }
                let preview = GenAIImportPreview(
                    map: mapFile, output: first, existing: existing, ownSource: source, declared: { declared[$0] })
                return Rendered(human: preview.text(dryRun: true), json: preview.json.with("dry_run", true))
            }

            let final = try engine.envelope(from: data, collector: importName, window: window, run: runID, generatedAt: now)
            let journal = try context.openJournal()
            let report = try journal.ingest(
                envelope: final.envelope, collector: importName, window: window, actor: .importer(importName),
                inbox: context.roots.inbox, skipped: final.skipped)
            guard report.status == "ok" else {
                throw CadenceError.validation("the import failed: " + (report.problems.first ?? "unknown error"))
            }
            let created = report.count("created"), updated = report.count("updated")
            let unchanged = report.count("unchanged"), skipped = report.count("skipped")
            var human =
                "Imported \(source) for \(low) to \(high): \(created) created, \(updated) updated, \(unchanged) unchanged, \(skipped) skipped."
            if !report.problems.isEmpty { human += "\n" + report.problems.map { "  \($0)" }.joined(separator: "\n") }
            if let inbox = report.inbox { human += "\nThe mapped records were kept in \(inbox.path)." }
            let json: JSONValue = [
                "dry_run": false, "name": .string(importName), "source": .string(source),
                "since": .string(low.description), "until": .string(high.description),
                "counts": [
                    "created": .int(created), "updated": .int(updated), "unchanged": .int(unchanged), "skipped": .int(skipped),
                ],
                "problems": .array(report.problems.map { .string($0) }),
                "inbox": report.inbox.map { .string($0.path) } ?? .null,
            ]
            return Rendered(human: human, json: json)
        }
    }

    static func read(_ path: String, what: String, limit: Int) throws(CadenceError) -> [UInt8] {
        let url = URL(fileURLWithPath: path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        guard let size else { throw .notFound("cannot read \(what) at \(path)") }
        guard size <= limit else { throw .validation("\(what) at \(path) is larger than \(limit / (1024 * 1024)) MB") }
        guard let data = FileManager.default.contents(atPath: url.path) else { throw .io("cannot read \(what) at \(path)") }
        return Array(data)
    }
}

extension JSONValue {
    func with(_ key: String, _ value: JSONValue) -> JSONValue {
        guard var object = objectValue else { return self }
        object[key] = value
        return .object(object)
    }
}
