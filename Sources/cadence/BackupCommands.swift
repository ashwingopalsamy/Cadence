import ArgumentParser
import CadenceCore
import Foundation

extension CLIContext {
    /// Backups of the store in the backups folder, on the profile's workday.
    func openBackups() throws(CadenceError) -> Backups {
        let config = try loadConfig().config
        guard let zone = TimeZone(identifier: config.profile.timezone) else {
            throw .validation("config: profile.timezone '\(config.profile.timezone)' is not a time zone")
        }
        let store = try openStore()
        return Backups(
            store: store, folder: roots.backups, clock: clock, zone: zone, boundary: config.dayBoundary)
    }
}

struct BackupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Back up the store: one snapshot per workday, 14 daily and 8 weekly kept.",
        discussion: "Does nothing when today's backup exists. Files are cadence-YYYY-MM-DD.db in the backups folder.",
        subcommands: [BackupList.self])

    @OptionGroup var output: OutputOptions
    @Flag(name: .long, help: "Replace today's backup if it exists.") var force = false

    func run() throws {
        try output.run { context in
            let result = try context.openBackups().run(force: force)
            let pruned = result.pruned.map(\.lastPathComponent)
            let name = result.file?.url.path ?? "-"
            var human: String
            if result.created {
                human = "Backed up \(result.events ?? 0) events to \(name), verified"
                if !pruned.isEmpty { human += "; removed \(pruned.count) old backup" + (pruned.count == 1 ? "" : "s") }
            } else {
                human = "Today's backup already exists: \(name). Use --force to replace it."
            }
            let json: JSONValue = [
                "created": .bool(result.created),
                "path": result.file.map { .string($0.url.path) } ?? .null,
                "day": result.file.map { .string($0.day.description) } ?? .null,
                "bytes": result.file.map { .int($0.bytes) } ?? .null,
                "events": result.events.map { .int($0) } ?? .null,
                "head": result.head.map { .string($0) } ?? .null,
                "pruned": .array(pruned.map { .string($0) }),
            ]
            return Rendered(human: human, json: json)
        }
    }
}

struct BackupList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List backups, newest first.",
        discussion: "With --verify each file is opened read-only and its integrity and hash chain are checked.")

    @OptionGroup var output: OutputOptions
    @Flag(name: .long, help: "Check every backup. Exits 2 if one is damaged.") var verify = false

    func run() throws {
        try output.run { context in
            let files = try context.openBackups().list(verify: verify)
            let rows = files.map { file -> [String] in
                var row = [file.day.description, "\(file.bytes) bytes"]
                if let check = file.check {
                    row.append(check.ok ? "ok, \(check.events) events" : "damaged: \(check.problems.joined(separator: "; "))")
                }
                return row
            }
            let human = files.isEmpty ? "No backups yet" : Format.table(rows)
            let json: JSONValue = [
                "backups": .array(
                    files.map { file in
                        var object: [String: JSONValue] = [
                            "day": .string(file.day.description), "path": .string(file.url.path), "bytes": .int(file.bytes),
                        ]
                        if let check = file.check {
                            object["ok"] = .bool(check.ok)
                            object["events"] = .int(check.events)
                            object["head"] = check.head.map { .string($0) } ?? .null
                            object["problems"] = .array(check.problems.map { .string($0) })
                        }
                        return .object(object)
                    })
            ]
            if files.contains(where: { $0.check?.ok == false }) {
                try output.emit(Rendered(human: human, json: json))
                throw CadenceError.integrity("one or more backups are damaged")
            }
            return Rendered(human: human, json: json)
        }
    }
}
