import ArgumentParser
import CadenceCore
import Foundation

struct PresenceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "presence", abstract: "Presence spans: backfill from the Mac's power log.",
        subcommands: [PresenceBackfill.self])
}

struct PresenceBackfill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backfill",
        abstract: "Add presence spans from the power log (pmset -g log), labelled power log.",
        discussion: "Wake and display on start a span; sleep and display off end it. Safe to run again: spans already recorded are skipped.")

    @OptionGroup var output: OutputOptions
    @Option(help: "First day to backfill, as YYYY-MM-DD.") var since: String
    @Flag(name: .customLong("dry-run"), help: "Show the days and spans without writing anything.") var dryRun = false
    @Option(help: "Read this saved pmset log instead of running pmset.") var file: String?

    func run() throws {
        try output.run { context in
            let first = try Args.required(since, option: "since")
            let config = try context.loadConfig().config
            guard let zone = TimeZone(identifier: config.profile.timezone) else {
                throw CadenceError.validation("config: profile.timezone '\(config.profile.timezone)' is not a time zone")
            }
            let now = context.clock.now()
            let today = config.dayBoundary.day(of: now, in: zone)
            guard first <= today else { throw CadenceError.validation("--since: \(first) is in the future") }

            let text = try Self.logText(file: file, home: context.roots.home)
            let parsed = PowerLogParser(zone: zone, boundary: config.dayBoundary).parse(text, now: now)
            let spans = parsed.spans.filter { $0.day >= first && $0.day <= today }
            let table = PowerLogDay.summarize(spans, in: zone)

            var written = 0
            var skipped = 0
            if !dryRun, !spans.isEmpty {
                let result = try context.openJournal().backfillPresence(spans: spans, actor: .cli)
                written = result.written
                skipped = result.skipped
            }

            var json: [String: JSONValue] = [
                "since": .string(first.description), "dry_run": .bool(dryRun), "spans": .int(Int64(spans.count)),
                "written": .int(Int64(written)), "skipped": .int(Int64(skipped)),
                "malformed": .int(Int64(parsed.malformed)),
                "days": .array(
                    table.map {
                        [
                            "date": .string($0.day.description), "first": .string($0.first), "last": .string($0.last),
                            "spans": .int(Int64($0.spans)),
                        ]
                    }),
            ]
            json["source"] = .string("powerlog")
            return Rendered(human: Self.human(table, spans: spans.count, written: written, skipped: skipped, parsed: parsed, since: first, dryRun: dryRun), json: .object(json))
        }
    }

    static func human(
        _ table: [PowerLogDay], spans: Int, written: Int, skipped: Int, parsed: PowerLogResult, since: LocalDate,
        dryRun: Bool
    ) -> String {
        var lines: [String] = []
        if table.isEmpty {
            lines.append("No power log spans since \(since). The log may no longer hold them.")
        } else {
            if dryRun {
                lines.append("Found \(spans) span\(spans == 1 ? "" : "s") on \(table.count) day\(table.count == 1 ? "" : "s"). Nothing written.")
            } else {
                var line = "Wrote \(written) span\(written == 1 ? "" : "s") on \(table.count) day\(table.count == 1 ? "" : "s")"
                if skipped > 0 { line += ", \(skipped) already recorded" }
                lines.append(line + ".")
            }
            lines.append("")
            lines.append("Date        First  Last   Spans")
            for row in table {
                lines.append("\(row.day)  \(Format.clock(row.first))  \(Format.clock(row.last))  \(row.spans)")
            }
        }
        if parsed.malformed > 0 {
            lines.append("")
            lines.append("Skipped \(parsed.malformed) line\(parsed.malformed == 1 ? "" : "s") that could not be read.")
        }
        return lines.joined(separator: "\n")
    }

    /// The saved log from `--file`, or the output of `pmset -g log` on a Mac.
    static func logText(file: String?, home: URL) throws(CadenceError) -> String {
        if let file {
            guard let data = FileManager.default.contents(atPath: file) else {
                throw .io("cannot read \(file)")
            }
            return String(decoding: data, as: UTF8.self)
        }
        #if os(macOS)
        let request = ProcessRequest(
            executable: "/usr/bin/pmset", arguments: ["-g", "log"], environment: ["LANG": "en_US.UTF-8"],
            workingDirectory: home, timeout: .seconds(30), stdoutLimit: 64 * 1024 * 1024)
        let result: ProcessResult
        do {
            result = try SystemProcessRunner().run(request)
        } catch let error as CadenceError {
            throw error
        } catch {
            throw .io("cannot run pmset: \(error.localizedDescription)")
        }
        if result.timedOut { throw .io("pmset took longer than 30 seconds") }
        guard result.succeeded else { throw .io("pmset failed: \(String(decoding: result.stderrTail, as: UTF8.self))") }
        if result.stdoutTruncated { throw .io("the power log is larger than 64 MB; use --file with a trimmed copy") }
        return String(decoding: result.stdout, as: UTF8.self)
        #else
        throw .io("presence backfill needs macOS")
        #endif
    }
}
