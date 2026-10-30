import ArgumentParser
import CadenceCore

// Every write here is made by the CLI and recorded with origin self (docs/SPEC.md section 9.5).

struct LogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "log", abstract: "Parse one line and record it.")

    @OptionGroup var output: OutputOptions
    @Argument(help: "What you did, in your own words.") var text: String
    @Option(help: "Override the parsed kind, for example work.done or review.given.") var kind: String?
    @Option(help: "Time of day as HH:MM, or an RFC 3339 time.") var at: String?
    @Option(help: "Day as YYYY-MM-DD.") var date: String?
    @Option(help: "A ticket key.") var ticket: String?
    @Option(name: .long, help: "An https link. Repeat for more.") var link: [String] = []
    @Option(help: "How many, 1 to 50.") var qty: Int64?
    @Option(help: "Minutes spent, 1 to 720.") var duration: Int64?
    @Option(help: "A private note kept with the entry.") var note: String?

    func run() throws {
        try output.run { context in
            var request = LogRequest(text: text)
            if let kind {
                guard let parsed = EntryKind(rawValue: kind) else {
                    let valid = EntryKind.allCases.map(\.rawValue).joined(separator: ", ")
                    throw CadenceError.validation("--kind: '\(kind)' is not valid; use one of \(valid)")
                }
                request.kind = parsed
            }
            request.occurredAt = at
            request.date = try Args.date(date)
            request.ticket = ticket
            request.links = link.map { Link.inferred(url: $0) }
            request.quantity = qty
            request.durationMin = duration
            request.note = note
            let journal = try context.openJournal()
            let entry = try journal.log(request, actor: .cli, origin: .selfReported)
            var human = "Logged for \(entry.day): \(entry.title)"
            human += "\n  \(entry.kind.rawValue), \(entry.family.rawValue)\(Format.ticket(entry.ticket))"
            if entry.backfilled { human += ", backfilled" }
            human += "\n  id \(entry.id)"
            return Rendered(human: human, json: ["entry": entry.json])
        }
    }
}

struct PlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan", abstract: "Manage the day's plan.",
        subcommands: [PlanAdd.self, PlanList.self, PlanDone.self, PlanSlip.self, PlanDrop.self])
}

struct PlanAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a task to a day's plan.")

    @OptionGroup var output: OutputOptions
    @Argument(help: "The task.") var title: String
    @Option(help: "Day as YYYY-MM-DD. Default: today.") var date: String?
    @Option(help: "Estimate in minutes.") var estimate: Int64?

    func run() throws {
        try output.run { context in
            let day = try Args.date(date)
            let journal = try context.openJournal()
            let task = try journal.planAdd(
                title: title, day: day, estimateMin: estimate, origin: .selfReported, actor: .cli)
            return Rendered(
                human: "Planned for \(task.day): \(task.title)\n  id \(task.id)", json: ["task": task.json])
        }
    }
}

struct PlanList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List a day's plan.")

    @OptionGroup var output: OutputOptions
    @Option(help: "Day as YYYY-MM-DD. Default: today.") var date: String?

    func run() throws {
        try output.run { context in
            let requested = try Args.date(date)
            let journal = try context.openJournal()
            let day = requested ?? journal.today()
            let tasks = try journal.dayView(day).tasks
            var lines = ["\(Format.planSummary(tasks)) for \(day)"]
            lines += tasks.map { "  " + Format.taskLine($0) }
            return Rendered(
                human: lines.joined(separator: "\n"),
                json: ["day": .string(day.description), "tasks": .array(tasks.map(\.json))])
        }
    }
}

/// Shared by `plan done`, `plan slip` and `plan drop`.
struct PlanResolveOptions: ParsableArguments {
    @OptionGroup var output: OutputOptions
    @Argument(help: "The task id.") var taskID: String
    @Option(help: "Why it slipped or was dropped, for example reprioritised.") var reason: String?
    @Option(help: "A note kept with the task.") var note: String?
    @Option(name: .long, help: "An entry id that finished the task. Repeat for more.") var link: [String] = []

    func resolve(as status: TaskStatus, verb: String) throws {
        try output.run { context in
            let journal = try context.openJournal()
            let task = try journal.planResolve(
                taskID: taskID, status: status, reason: reason, note: note, links: link, actor: .cli)
            return Rendered(human: "Task \(verb): \(task.title)", json: ["task": task.json])
        }
    }
}

struct PlanDone: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "done", abstract: "Mark a task done.")
    @OptionGroup var options: PlanResolveOptions
    func run() throws { try options.resolve(as: .done, verb: "done") }
}

struct PlanSlip: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slip", abstract: "Mark a task slipped. A reason is required.")
    @OptionGroup var options: PlanResolveOptions
    func run() throws { try options.resolve(as: .slipped, verb: "slipped") }
}

struct PlanDrop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "drop", abstract: "Mark a task dropped.")
    @OptionGroup var options: PlanResolveOptions
    func run() throws { try options.resolve(as: .dropped, verb: "dropped") }
}

struct DayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "day", abstract: "Day start, end, leave, holidays, wrap-up and the day view.",
        subcommands: [DayStart.self, DayEnd.self, DayLeave.self, DayHoliday.self, DayShow.self, DaySeal.self])
}

struct DayStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Record when the day started.")

    @OptionGroup var output: OutputOptions
    @Option(help: "Day as YYYY-MM-DD. Default: today.") var date: String?
    @Option(help: "Time as HH:MM. Default: now.") var at: String?

    func run() throws {
        try output.run { context in
            let day = try Args.date(date)
            let journal = try context.openJournal()
            try journal.startDay(day, at: at, actor: .cli)
            let view = try journal.dayView(day ?? journal.today())
            return Rendered(
                human: "Day \(view.day.date) started at \(Format.clock(view.day.firstActivity))",
                json: ["day": view.day.json])
        }
    }
}

struct DayEnd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "end", abstract: "Record when the day ended.")

    @OptionGroup var output: OutputOptions
    @Option(help: "Day as YYYY-MM-DD. Default: today.") var date: String?
    @Option(help: "Time as HH:MM. Default: now.") var at: String?

    func run() throws {
        try output.run { context in
            let day = try Args.date(date)
            let journal = try context.openJournal()
            try journal.endDay(day, at: at, actor: .cli)
            let view = try journal.dayView(day ?? journal.today())
            return Rendered(
                human: "Day \(view.day.date) ended at \(Format.clock(view.day.lastActivity))",
                json: ["day": view.day.json])
        }
    }
}

struct DayLeave: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "leave", abstract: "Mark a day as leave.")

    @OptionGroup var output: OutputOptions
    @Argument(help: "Day as YYYY-MM-DD.") var date: String
    @Flag(help: "Leave that was not planned.") var unplanned = false
    @Option(help: "A short label.") var label: String?

    func run() throws {
        try output.run { context in
            let day = try Args.required(date, option: "date")
            let journal = try context.openJournal()
            try journal.declare(day, kind: unplanned ? .leaveUnplanned : .leavePlanned, label: label, actor: .cli)
            let view = try journal.dayView(day)
            return Rendered(
                human: "Marked \(view.day.date) as \(Format.kind(view.day.kind))", json: ["day": view.day.json])
        }
    }
}

struct DayHoliday: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "holiday", abstract: "Mark a day as a holiday.")

    @OptionGroup var output: OutputOptions
    @Argument(help: "Day as YYYY-MM-DD.") var date: String
    @Option(help: "A short label.") var label: String?

    func run() throws {
        try output.run { context in
            let day = try Args.required(date, option: "date")
            let journal = try context.openJournal()
            try journal.declare(day, kind: .holiday, label: label, actor: .cli)
            let view = try journal.dayView(day)
            return Rendered(
                human: "Marked \(view.day.date) as \(Format.kind(view.day.kind))", json: ["day": view.day.json])
        }
    }
}
