import CadenceCore
import Foundation

/// The nine tools (docs/SPEC.md section 9.2), in the order `tools/list` returns them. Claude Code can log,
/// plan and read; it cannot accept its own proposals, seal a day, delete, change config or touch presence, so
/// no tool does any of that. Every write goes through the same `Journal` functions the CLI uses, with actor
/// `mcp` and origin `agent`.
extension CadenceMCP {
    public static let toolNames = [
        "log_entry", "log_entries", "plan_add", "plan_update", "declare_day", "get_day", "query", "summary", "standup",
    ]

    /// At most this many entries in one `log_entries` call, so the preview table always fits a result.
    public static let maxBatch = 25

    public static func tools(journal makeJournal: @escaping JournalProvider) -> [MCPTool] {
        [
            logEntryTool(makeJournal), logEntriesTool(makeJournal), planAddTool(makeJournal), planUpdateTool(makeJournal),
            declareDayTool(makeJournal), getDayTool(makeJournal), queryTool(makeJournal), summaryTool(makeJournal), standupTool(makeJournal),
        ]
    }

    /// Kinds only the machine side records: AI sessions and usage from the hooks and collectors, and presence.
    /// An agent saying so would make the log less honest.
    static let systemKinds: Set<EntryKind> = [.genaiSession, .genaiUsage, .presenceSpan]
    static var agentKinds: [EntryKind] { EntryKind.allCases.filter { !systemKinds.contains($0) } }
}

// MARK: - log_entry and log_entries

extension CadenceMCP {
    static func entryProperties() -> [String: JSONValue] {
        [
            "text": Schema.string(maxLength: 500),
            "kind": Schema.string(description: "Override the parsed kind, e.g. work.done, review.given, discussion.raised"),
            "date": Schema.date(),
            "occurred_at": Schema.string(description: "RFC 3339, or HH:MM in local time"),
            "ticket": Schema.string(),
            "links": [
                "type": "array", "maxItems": 5,
                "items": [
                    "type": "object", "required": ["url"],
                    "properties": [
                        "url": ["type": "string", "format": "uri"], "kind": ["enum": ["pr", "ticket", "doc", "other"]],
                    ],
                ],
            ],
            "duration_min": ["type": "integer", "minimum": 1, "maximum": 720],
            "quantity": ["type": "integer", "minimum": 1, "maximum": 50],
            "note": Schema.string(maxLength: 1000),
        ]
    }

    static let logEntrySchema: JSONValue = Schema.object(entryProperties(), required: ["text"])

    /// The request one entry's arguments describe. Used by `log_entry` and by each item of `log_entries`.
    static func logRequest(_ object: [String: JSONValue]) throws(CadenceError) -> LogRequest {
        let arguments = ToolArguments(object)
        guard let text = arguments.string("text") else { throw .validation("text: is required") }
        var request = LogRequest(text: text)
        if let kind = arguments.string("kind") {
            guard let parsed = EntryKind(rawValue: kind), !systemKinds.contains(parsed) else {
                throw .validation("kind: '\(EnvelopeText.printable(kind))' is not valid; use one of \(agentKinds.map(\.rawValue).joined(separator: ", "))")
            }
            request.kind = parsed
        }
        request.date = try arguments.date("date")
        request.occurredAt = arguments.string("occurred_at")
        request.ticket = arguments.string("ticket")
        for item in arguments.array("links") ?? [] {
            guard let url = item["url"]?.stringValue else { throw .validation("links: every link needs a url") }
            if let name = item["kind"]?.stringValue, let kind = LinkKind(rawValue: name) {
                request.links.append(Link(kind: kind, url: url))
            } else {
                request.links.append(Link.inferred(url: url))
            }
        }
        request.durationMin = arguments.int("duration_min")
        request.quantity = arguments.int("quantity")
        request.note = arguments.string("note")
        return request
    }

    static func logEntryTool(_ makeJournal: @escaping JournalProvider) -> MCPTool {
        MCPTool(
            name: "log_entry",
            description:
                "Record one work outcome in Cadence, the user's local work log. Use after finishing something the user would mention in stand-up. Prefer 'text' in the user's words; Cadence parses ticket keys, kind, time and duration. Do not log routine tool calls.",
            inputSchema: logEntrySchema, writes: true,
            call: { arguments throws(CadenceError) in
                do throws(CadenceError) {
                    let request = try logRequest(arguments)
                    let entry = try makeJournal().log(request, actor: .mcp, origin: .agent)
                    let when = ToolText.day(entry.day)
                    let what = entry.title + ToolText.ticketSuffix(entry.ticket, in: entry.title)
                    let text =
                        entry.status == .accepted
                        ? "Logged for \(when): \(what)."
                        : "Proposed for \(when): \(what). It is waiting in the user's Inbox, and only the user can accept it."
                    return MCPToolResult(
                        text: text, structured: ["status": .string(entry.status.rawValue), "entry": ToolText.loggedEntry(entry)])
                } catch {
                    throw ToolText.forAgent(error)
                }
            })
    }

    /// One line of a `log_entries` call: what it would record, or why it cannot be recorded.
    struct Line {
        var number: Int
        var request: LogRequest
        var entry: Entry?
        var problem: String?
    }

    static func logEntriesTool(_ makeJournal: @escaping JournalProvider) -> MCPTool {
        let properties: [String: JSONValue] = [
            "transcript": Schema.string(
                maxLength: 20_000,
                description:
                    "Pasted dictation or notes, one outcome per line or bullet, exactly as the user gave it. Cadence splits it and parses each line. A line that is only a day, such as 'Wed 28 Oct', sets the day for the lines after it."
            ),
            "entries": Schema.array(
                of: logEntrySchema, maxItems: maxBatch,
                description: "A list of entries, each shaped like the log_entry arguments. Use either this or 'transcript'."),
            "date": Schema.date(
                description:
                    "The day the entries are for, such as the day the dictation was recorded. A line that names its own day keeps it. Default: today."
            ),
            "dry_run": Schema.boolean(
                description:
                    "Default true: return a preview table and record nothing. Pass false only after the user has seen the preview and agreed."
            ),
        ]
        return MCPTool(
            name: "log_entries",
            description:
                "Record many work outcomes at once, such as a dictation transcript. Pass the pasted text as 'transcript', or a list as 'entries'. dry_run defaults to true: Cadence returns a preview table and records nothing. Show the table to the user, and call again with dry_run false only after they agree. Entries land in the user's Inbox as proposals, whatever their day; only the user can accept them. At most \(maxBatch) entries per call.",
            inputSchema: Schema.object(properties), writes: true,
            call: { arguments throws(CadenceError) in
                do throws(CadenceError) {
                    return try logEntries(ToolArguments(arguments), journal: try makeJournal())
                } catch {
                    throw ToolText.forAgent(error)
                }
            })
    }

    static func logEntries(_ arguments: ToolArguments, journal: Journal) throws(CadenceError) -> MCPToolResult {
        let dryRun = arguments.bool("dry_run") ?? true
        let transcript = arguments.string("transcript")
        let list = arguments.array("entries")
        if transcript != nil, list != nil { throw .validation("give either transcript or entries, not both") }
        guard transcript != nil || list != nil else { throw .validation("give a transcript or a list of entries") }
        let date = try arguments.date("date")

        // One line per request. A line that cannot even be built is kept, with its problem, so the preview
        // shows every problem at once.
        var lines: [Line] = []
        if let transcript {
            for request in journal.requests(fromTranscript: transcript, date: date) {
                lines.append(Line(number: lines.count + 1, request: request))
            }
            guard !lines.isEmpty else { throw .validation("there is nothing to record: the transcript has no lines") }
        } else {
            guard let list, !list.isEmpty else { throw .validation("entries: give at least one entry") }
            for item in list {
                var line = Line(number: lines.count + 1, request: LogRequest(text: item["text"]?.stringValue ?? ""))
                do throws(CadenceError) {
                    var request = try logRequest(item.objectValue ?? [:])
                    request.date = request.date ?? date
                    request.proposed = true
                    line.request = request
                } catch {
                    line.problem = error.message
                }
                lines.append(line)
            }
        }
        guard lines.count <= maxBatch else {
            throw .validation("\(lines.count) entries is more than \(maxBatch) in one call; send them in batches")
        }

        for index in lines.indices where lines[index].problem == nil {
            do throws(CadenceError) {
                lines[index].entry = try journal.preview(lines[index].request, origin: .agent)
            } catch {
                lines[index].problem = ToolText.forAgent(error).message
            }
        }
        let problems = lines.filter { $0.problem != nil }

        if dryRun {
            let intro =
                problems.isEmpty
                ? "Preview: \(ToolText.entries(lines.count)) for the Inbox. Nothing is recorded yet."
                : "Preview: \(lines.count) lines, \(problems.count) cannot be recorded. Nothing is recorded yet."
            let outro =
                problems.isEmpty
                ? "Show this table to the user. After they agree, call log_entries again with the same input and dry_run false."
                : "Fix or drop the lines marked not recorded, show the user the table, and call again with dry_run false only after they agree. A real call refuses the whole batch while any line has a problem."
            return MCPToolResult(
                text: [intro, table(lines, finalColumn: "NOTE"), outro].joined(separator: "\n"),
                structured: [
                    "status": "preview", "dry_run": true, "recorded": 0, "problems": .int(Int64(problems.count)),
                    "entries": .array(lines.map(row)),
                ])
        }

        guard problems.isEmpty else {
            let list = problems.map { "line \($0.number): \($0.problem ?? "")" }.joined(separator: "; ")
            throw .validation("nothing was recorded, because \(problems.count) of \(lines.count) lines cannot be: \(list). Fix or drop them and call again")
        }
        let entries = try journal.logAll(lines.map(\.request), actor: .mcp, origin: .agent)
        for (index, entry) in entries.enumerated() { lines[index].entry = entry }
        return MCPToolResult(
            text: [
                "Put \(ToolText.entries(entries.count)) in the user's Inbox as proposals. They count only once the user accepts them.",
                table(lines, finalColumn: "ID"),
            ].joined(separator: "\n"),
            structured: [
                "status": "proposed", "dry_run": false, "recorded": .int(Int64(entries.count)), "problems": 0,
                "entries": .array(lines.map(row)),
            ])
    }

    private static func table(_ lines: [Line], finalColumn: String) -> String {
        var rows = [["#", "DAY", "TIME", "KIND", "TITLE", finalColumn]]
        for line in lines {
            if let entry = line.entry {
                let last = finalColumn == "ID" ? entry.id : "ok"
                rows.append([
                    String(line.number), entry.day, Format.clock(entry.occurredAt), entry.kind.rawValue,
                    entry.title + ToolText.ticketSuffix(entry.ticket, in: entry.title), last,
                ])
            } else {
                rows.append([String(line.number), "-", "-", "-", ToolText.oneLine(line.request.text, limit: 80), "not recorded: \(line.problem ?? "")"])
            }
        }
        return Format.table(rows)
    }

    private static func row(_ line: Line) -> JSONValue {
        var object: [String: JSONValue] = ["line": .int(Int64(line.number))]
        if let entry = line.entry, let listed = ToolText.listedEntry(entry).objectValue {
            for (key, value) in listed where !(key == "id" && entry.id.isEmpty) { object[key] = value }
        } else {
            object["text"] = .string(ToolText.oneLine(line.request.text, limit: 200))
            object["problem"] = .string(line.problem ?? "")
        }
        return .object(object)
    }
}

// MARK: - plan_add, plan_update and declare_day

extension CadenceMCP {
    static func planAddTool(_ makeJournal: @escaping JournalProvider) -> MCPTool {
        MCPTool(
            name: "plan_add",
            description:
                "Add tasks to a day's plan, today unless 'date' is given. Use when the user says what they will work on. Tasks are recorded as suggested by the agent, so the user can tell them from their own. Each result line carries the task id that plan_update needs.",
            inputSchema: Schema.object(
                [
                    "date": Schema.date(description: "The day to plan. Default: today."),
                    "tasks": Schema.array(
                        of: Schema.object(
                            [
                                "title": Schema.string(minLength: 1, maxLength: 200, description: "The task, in the user's words. A ticket key in it is picked up."),
                                "estimate_min": Schema.integer(minimum: 1, maximum: 1440, description: "Estimate in minutes."),
                            ], required: ["title"]),
                        maxItems: 20),
                ], required: ["tasks"]),
            writes: true,
            call: { arguments throws(CadenceError) in
                do throws(CadenceError) {
                    let input = ToolArguments(arguments)
                    let day = try input.date("date")
                    let items = input.array("tasks") ?? []
                    guard !items.isEmpty else { throw .validation("tasks: give at least one task") }
                    let journal = try makeJournal()
                    let tasks = try journal.store.transact { () throws(CadenceError) -> [PlanTask] in
                        var added: [PlanTask] = []
                        for item in items {
                            added.append(
                                try journal.planAdd(
                                    title: item["title"]?.stringValue ?? "", day: day, estimateMin: item["estimate_min"]?.intValue,
                                    origin: .suggested, actor: .mcp))
                        }
                        return added
                    }
                    let when = ToolText.day(tasks.first?.day ?? "")
                    let head = "Planned for \(when): \(ToolText.plural(tasks.count, "task")) added."
                    return MCPToolResult(
                        text: ([head] + tasks.map { "  " + Format.taskLine($0) }).joined(separator: "\n"),
                        structured: [
                            "day": .string(tasks.first?.day ?? ""), "tasks": .array(tasks.map(ToolText.listedTask)),
                        ])
                } catch {
                    throw ToolText.forAgent(error)
                }
            })
    }

    static func planUpdateTool(_ makeJournal: @escaping JournalProvider) -> MCPTool {
        MCPTool(
            name: "plan_update",
            description:
                "Resolve or edit a plan task by id. Set status to done when the work is finished, slipped when it did not happen (give a short reason such as reprioritised or blocked; a slip needs one), or dropped when it was cancelled. Or change an open task's title or estimate_min. Get task ids from get_day or plan_add. Do not resolve a task the user has not said is finished.",
            inputSchema: Schema.object(
                [
                    "task_id": Schema.string(minLength: 1, maxLength: 64),
                    "status": Schema.choice(["done", "slipped", "dropped"], description: "How the task ended."),
                    "reason": Schema.string(maxLength: 100, description: "Why it slipped or was dropped, such as reprioritised or blocked."),
                    "note": Schema.string(maxLength: 1000, description: "A note kept with the resolution."),
                    "entry_ids": Schema.array(
                        of: Schema.string(minLength: 1, maxLength: 64), maxItems: 10,
                        description: "Ids of entries that finished the task."),
                    "title": Schema.string(minLength: 1, maxLength: 200, description: "A new title for an open task."),
                    "estimate_min": Schema.integer(minimum: 1, maximum: 1440, description: "A new estimate for an open task, in minutes."),
                ], required: ["task_id"]),
            writes: true,
            call: { arguments throws(CadenceError) in
                do throws(CadenceError) {
                    let input = ToolArguments(arguments)
                    guard let id = input.string("task_id") else { throw .validation("task_id: is required") }
                    var status: TaskStatus?
                    if let name = input.string("status") {
                        guard let parsed = TaskStatus(rawValue: name), parsed.isResolved else {
                            throw .validation("status: must be done, slipped or dropped")
                        }
                        status = parsed
                    }
                    let title = input.string("title")
                    let estimate = input.int("estimate_min")
                    guard status != nil || title != nil || estimate != nil else {
                        throw .validation("give a status to resolve the task, or a title or estimate_min to edit it")
                    }
                    if status == nil, input.string("reason") != nil || input.string("note") != nil || input.array("entry_ids") != nil {
                        throw .validation("reason, note and entry_ids go with a status")
                    }
                    if input.string("reason") != nil, status == .done {
                        throw .validation("reason: only for a slipped or dropped task")
                    }
                    let journal = try makeJournal()
                    let task = try journal.store.transact { () throws(CadenceError) -> PlanTask in
                        if title != nil || estimate != nil {
                            _ = try journal.planEdit(taskID: id, title: title, estimateMin: estimate, actor: .mcp)
                        }
                        guard let status else { return try journal.task(id) }
                        return try journal.planResolve(
                            taskID: id, status: status, reason: input.string("reason"), note: input.string("note"),
                            links: (input.array("entry_ids") ?? []).compactMap(\.stringValue), actor: .mcp)
                    }
                    let verb: String
                    switch status {
                    case .done?: verb = "Marked done"
                    case .slipped?: verb = "Marked slipped"
                    case .dropped?: verb = "Marked dropped"
                    default: verb = "Updated"
                    }
                    return MCPToolResult(
                        text: "\(verb): \(Format.taskLine(task))", structured: ["task": ToolText.listedTask(task)])
                } catch {
                    throw ToolText.forAgent(error)
                }
            })
    }

    static func declareDayTool(_ makeJournal: @escaping JournalProvider) -> MCPTool {
        MCPTool(
            name: "declare_day",
            description:
                "Mark a day as a holiday, planned leave or unplanned leave, so streaks and plan counts skip it. Use only when the user says so; never to explain a missing day.",
            inputSchema: Schema.object(
                [
                    "date": Schema.date(),
                    "kind": Schema.choice(["holiday", "leave_planned", "leave_unplanned"]),
                    "label": Schema.string(maxLength: 100, description: "A short label such as the holiday's name."),
                ], required: ["date", "kind"]),
            writes: true,
            call: { arguments throws(CadenceError) in
                do throws(CadenceError) {
                    let input = ToolArguments(arguments)
                    guard let day = try input.date("date") else { throw .validation("date: is required") }
                    guard let kind = input.string("kind").flatMap({ DayKind(rawValue: $0) }), kind.isLeaveOrHoliday else {
                        throw .validation("kind: must be holiday, leave_planned or leave_unplanned")
                    }
                    let journal = try makeJournal()
                    try journal.declare(day, kind: kind, label: input.string("label"), actor: .mcp)
                    let view = try journal.dayView(day)
                    var text = "Marked \(ToolText.day(view.day.date)) as \(Format.kind(view.day.kind))"
                    if let label = view.day.label { text += ": \(label)" }
                    return MCPToolResult(text: text + ".", structured: ["day": view.day.json])
                } catch {
                    throw ToolText.forAgent(error)
                }
            })
    }
}

// MARK: - get_day, query, summary and standup

extension CadenceMCP {
    static func getDayTool(_ makeJournal: @escaping JournalProvider) -> MCPTool {
        MCPTool(
            name: "get_day",
            description:
                "Read one day: its plan, entries, presence and ring. Defaults to today. Entries still waiting in the Inbox show as proposed.",
            inputSchema: Schema.object(["date": Schema.date(description: "The day. Default: today.")]),
            writes: false,
            call: { arguments throws(CadenceError) in
                do throws(CadenceError) {
                    let journal = try makeJournal()
                    let view = try journal.dayView(try ToolArguments(arguments).date("date") ?? journal.today())
                    return dayResult(view)
                } catch {
                    throw ToolText.forAgent(error)
                }
            })
    }

    /// The day as text and JSON, with as many entries as fit a result; the rest are one `query` away.
    static func dayResult(_ view: DayView) -> MCPToolResult {
        func render(_ count: Int) -> MCPToolResult {
            var shown = view
            shown.entries = Array(view.entries.prefix(count))
            var text = DayRendering.human(shown)
            if count < view.entries.count {
                text += "\nShowing \(count) of \(view.entries.count) entries; use query for this date to page through the rest."
            }
            text += "\n\n" + DayRing(view).text
            let presence = view.presence.map { span -> JSONValue in
                ["start": .string(span.start), "end": .string(span.end), "source": .string(span.source.rawValue)]
            }
            return MCPToolResult(
                text: text,
                structured: [
                    "day": view.day.json, "tasks": .array(view.tasks.map(ToolText.listedTask)),
                    "entries": .array(shown.entries.map(ToolText.listedEntry)), "entries_total": .int(Int64(view.entries.count)),
                    "presence": .array(presence), "ring": DayRing(view).json,
                ])
        }
        return render(ToolText.largestFit(of: view.entries.count, render: render))
    }

    static func queryTool(_ makeJournal: @escaping JournalProvider) -> MCPTool {
        MCPTool(
            name: "query",
            description:
                "Read entries in a date range, filtered by kind, family, origin or status. Dates default to today. Returns up to 200 entries per page, fewer when the page would be too long. When next_cursor is set, call again with it as 'cursor' and the same filters to continue.",
            inputSchema: Schema.object([
                "from": Schema.date(description: "First day. Default: the last day."),
                "to": Schema.date(description: "Last day. Default: today."),
                "kinds": Schema.array(of: Schema.choice(EntryKind.allCases.map(\.rawValue)), maxItems: 20, description: "Only these kinds."),
                "families": Schema.array(of: Schema.choice(Family.allCases.map(\.rawValue)), maxItems: 7, description: "Only these families."),
                "origins": Schema.array(of: Schema.choice(Origin.allCases.map(\.rawValue)), maxItems: 4, description: "Only these origins."),
                "statuses": Schema.array(
                    of: Schema.choice(EntryStatus.allCases.map(\.rawValue)), maxItems: 4,
                    description: "Only these statuses. Default: accepted and proposed."),
                "cursor": Schema.string(maxLength: 100, description: "The next_cursor of the previous page."),
                "limit": Schema.integer(minimum: 1, maximum: EntryQuery.maxLimit, description: "Entries per page. Default and most: 200."),
            ]),
            writes: false,
            call: { arguments throws(CadenceError) in
                do throws(CadenceError) {
                    return try query(ToolArguments(arguments), journal: try makeJournal())
                } catch {
                    throw ToolText.forAgent(error)
                }
            })
    }

    static func query(_ input: ToolArguments, journal: Journal) throws(CadenceError) -> MCPToolResult {
        let last = try input.date("to") ?? journal.today()
        let first = try input.date("from") ?? last
        var query = EntryQuery(from: first, to: last)
        query.kinds = try input.values("kinds", as: EntryKind.self)
        query.families = try input.values("families", as: Family.self)
        query.origins = try input.values("origins", as: Origin.self)
        let statuses = try input.values("statuses", as: EntryStatus.self)
        if !statuses.isEmpty { query.statuses = statuses }
        query.cursor = input.string("cursor")
        query.limit = Int(input.int("limit") ?? Int64(EntryQuery.maxLimit))

        func render(_ entries: [Entry], next: String?) -> MCPToolResult {
            var text: String
            if entries.isEmpty {
                text = "No entries from \(first) to \(last)."
            } else {
                text = "Entries from \(first) to \(last): \(entries.count) on this page.\n"
                text += Format.table(
                    [["DAY", "TIME", "KIND", "STATUS", "TITLE", "ID"]]
                        + entries.map {
                            [$0.day, Format.clock($0.occurredAt), $0.kind.rawValue, $0.status.rawValue,
                             $0.title + ToolText.ticketSuffix($0.ticket, in: $0.title), $0.id]
                        })
            }
            if let next { text += "\nMore entries: call query again with cursor \(next)." }
            return MCPToolResult(
                text: text,
                structured: [
                    "from": .string(first.description), "to": .string(last.description), "count": .int(Int64(entries.count)),
                    "entries": .array(entries.map(ToolText.listedEntry)), "next_cursor": next.map { .string($0) } ?? .null,
                ])
        }

        var page = try journal.query(query)
        // A full page of long titles can pass the result limit. Ask again for the largest page that fits, from
        // the same cursor, so the next cursor still lands right after the last entry shown.
        let sample = page.next ?? "0123456789ABCDEFGHIJ"
        if ToolText.size(of: render(page.entries, next: page.next)) > ToolText.budget {
            query.limit = ToolText.largestFit(of: page.entries.count) { render(Array(page.entries.prefix($0)), next: sample) }
            page = try journal.query(query)
        }
        return render(page.entries, next: page.next)
    }

    static func summaryTool(_ makeJournal: @escaping JournalProvider) -> MCPTool {
        MCPTool(
            name: "summary",
            description:
                "Read counts, streak, plan accuracy and findings for a range: week, month, cycle, or two days as YYYY-MM-DD..YYYY-MM-DD. Default: week. A dash or null means there is no data, which is not the same as zero.",
            inputSchema: Schema.object([
                "range": Schema.string(maxLength: 30, description: "week, month, cycle or YYYY-MM-DD..YYYY-MM-DD. Default: week.")
            ]),
            writes: false,
            call: { arguments throws(CadenceError) in
                do throws(CadenceError) {
                    let range = try SummaryRange.parse(ToolArguments(arguments).string("range") ?? "week")
                    let summary = try makeJournal().summary(range)
                    return MCPToolResult(text: SummaryRendering.human(summary), structured: summary.json)
                } catch {
                    throw ToolText.forAgent(error)
                }
            })
    }

    static func standupTool(_ makeJournal: @escaping JournalProvider) -> MCPTool {
        MCPTool(
            name: "standup",
            description:
                "Read the stand-up text for a day (default today): done, next and blockers. It carries no witness code; the user gets one from cadence standup or the app. Show it as it is and do not add items that are not in the log.",
            inputSchema: Schema.object(["date": Schema.date(description: "The day. Default: today.")]),
            writes: false,
            call: { arguments throws(CadenceError) in
                do throws(CadenceError) {
                    let journal = try makeJournal()
                    let day = try ToolArguments(arguments).date("date") ?? journal.today()
                    let text = try journal.standupText(day)
                    return MCPToolResult(text: text, structured: ["day": .string(day.description), "text": .string(text)])
                } catch {
                    throw ToolText.forAgent(error)
                }
            })
    }
}
