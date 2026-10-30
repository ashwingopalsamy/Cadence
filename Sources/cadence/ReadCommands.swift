import ArgumentParser
import CadenceCore
import Foundation

struct TodayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "today", abstract: "Today's plan, entries and presence.")

    @OptionGroup var output: OutputOptions

    func run() throws {
        try output.run { context in
            let journal = try context.openJournal()
            let view = try journal.dayView(journal.today())
            return Rendered(human: DayRendering.human(view), json: DayRendering.json(view))
        }
    }
}

struct DayShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one day.")

    @OptionGroup var output: OutputOptions
    @Option(help: "Day as YYYY-MM-DD. Default: today.") var date: String?

    func run() throws {
        try output.run { context in
            let requested = try Args.date(date)
            let journal = try context.openJournal()
            let view = try journal.dayView(requested ?? journal.today())
            return Rendered(human: DayRendering.human(view), json: DayRendering.json(view))
        }
    }
}

struct InboxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inbox", abstract: "Review proposals from agents, dictation and backfill.",
        subcommands: [InboxList.self, InboxAccept.self, InboxDismiss.self])
}

struct InboxList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List proposed entries.")

    @OptionGroup var output: OutputOptions

    func run() throws {
        try output.run { context in
            let entries = try context.openJournal().inbox()
            let human =
                entries.isEmpty
                ? "The inbox is empty."
                : "Proposed entries: \(entries.count)\n"
                    + entries.map { "  \($0.day)  \(Format.entryLine($0))  from \($0.origin.rawValue)" }.joined(separator: "\n")
            return Rendered(human: human, json: ["entries": .array(entries.map(\.json))])
        }
    }
}

struct InboxDecision: ParsableArguments {
    @OptionGroup var output: OutputOptions
    @Argument(help: "The entry id.") var entryID: String
    @Option(help: "A note kept with the decision.") var note: String?

    func decide(_ status: EntryStatus, verb: String) throws {
        try output.run { context in
            let entry = try context.openJournal().setStatus(entryID: entryID, to: status, note: note, actor: .cli)
            return Rendered(human: "Entry \(verb): \(entry.title)", json: ["entry": entry.json])
        }
    }
}

struct InboxAccept: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "accept", abstract: "Accept a proposed entry.")
    @OptionGroup var options: InboxDecision
    func run() throws { try options.decide(.accepted, verb: "accepted") }
}

struct InboxDismiss: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dismiss", abstract: "Dismiss a proposed entry.")
    @OptionGroup var options: InboxDecision
    func run() throws { try options.decide(.dismissed, verb: "dismissed") }
}

struct QueryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query", abstract: "Entries in a range, as a table, JSON or NDJSON.")

    @OptionGroup var output: OutputOptions
    @Option(help: "First day, YYYY-MM-DD. Default: the last day.") var from: String?
    @Option(help: "Last day, YYYY-MM-DD. Default: today.") var to: String?
    @Option(name: .long, help: "Only this kind. Repeat for more.") var kind: [String] = []
    @Option(name: .long, help: "Only this family. Repeat for more.") var family: [String] = []
    @Option(name: .long, help: "Only this origin. Repeat for more.") var origin: [String] = []
    @Option(name: .long, help: "Only this status. Repeat for more. Default: accepted and proposed.") var status: [String] = []
    @Flag(help: "One JSON entry per line.") var ndjson = false
    @Option(help: "Continue after this cursor.") var cursor: String?
    @Option(help: "Entries per page, at most 200.") var limit: Int = 200

    func run() throws {
        try output.run { context in
            let journal = try context.openJournal()
            let last = try Args.date(to, option: "to") ?? journal.today()
            let first = try Args.date(from, option: "from") ?? last
            var query = EntryQuery(from: first, to: last)
            query.kinds = try Args.values(kind, option: "kind", as: EntryKind.self)
            query.families = try Args.values(family, option: "family", as: Family.self)
            query.origins = try Args.values(origin, option: "origin", as: Origin.self)
            let statuses = try Args.values(status, option: "status", as: EntryStatus.self)
            if !statuses.isEmpty { query.statuses = statuses }
            query.cursor = cursor
            query.limit = limit
            let page = try journal.query(query)

            if ndjson {
                for entry in page.entries { writeLine(try OutputOptions.canonical(entry.json), to: FileHandle.standardOutput) }
                if let next = page.next {
                    writeLine("cadence: more entries; continue with --cursor \(next)", to: FileHandle.standardError)
                }
                return Rendered(human: "", json: .null, streamed: true)
            }
            var human: String
            if page.entries.isEmpty {
                human = "No entries from \(first) to \(last)."
            } else {
                human = Format.table(
                    [["DAY", "TIME", "KIND", "STATUS", "TITLE", "ID"]]
                        + page.entries.map {
                            [$0.day, Format.clock($0.occurredAt), $0.kind.rawValue, $0.status.rawValue, $0.title, $0.id]
                        })
            }
            if let next = page.next { human += "\nMore entries: continue with --cursor \(next)" }
            return Rendered(
                human: human,
                json: ["entries": .array(page.entries.map(\.json)), "next": page.next.map { .string($0) } ?? .null])
        }
    }
}
