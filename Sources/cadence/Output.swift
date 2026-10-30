import ArgumentParser
import CadenceCore
import Foundation

/// What a command produces: plain text for people, one JSON object for `--json`.
struct Rendered {
    var human: String
    var json: JSONValue
    /// True when the command already wrote its own output (NDJSON).
    var streamed = false
}

/// The flag every command shares.
struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Print one JSON object instead of text.") var json = false

    /// Runs `body`, prints its result, and turns a `CadenceError` into `cadence: <message>` on stderr and
    /// the exit code from docs/SPEC.md section 9.5. Entry titles are never written to stderr.
    func run(_ body: (CLIContext) throws -> Rendered) throws {
        do {
            let rendered = try body(CLIContext.current())
            try emit(rendered)
        } catch let error as CadenceError {
            throw fail(error)
        } catch let error as ExitCode {
            throw error
        } catch {
            throw fail(.io(String(describing: error)))
        }
    }

    func emit(_ rendered: Rendered) throws(CadenceError) {
        if rendered.streamed { return }
        if json {
            writeLine(try Self.canonical(rendered.json), to: FileHandle.standardOutput)
        } else {
            writeLine(rendered.human, to: FileHandle.standardOutput)
        }
    }

    static func canonical(_ value: JSONValue) throws(CadenceError) -> String {
        do {
            return try CanonicalJSON.string(value)
        } catch {
            throw .io("cannot encode the result as JSON")
        }
    }
}

func fail(_ error: CadenceError) -> ExitCode {
    writeLine("cadence: \(error.message)", to: FileHandle.standardError)
    return ExitCode(error.exitCode)
}

func writeLine(_ text: String, to handle: FileHandle) {
    handle.write(Data((text + "\n").utf8))
}

// MARK: - Argument parsing

enum Args {
    static func date(_ text: String?, option: String = "date") throws(CadenceError) -> LocalDate? {
        guard let text else { return nil }
        guard let date = LocalDate(text) else {
            throw .validation("--\(option): '\(text)' is not a date; use YYYY-MM-DD")
        }
        return date
    }

    static func required(_ text: String, option: String) throws(CadenceError) -> LocalDate {
        guard let date = try date(text, option: option) else { throw .validation("--\(option) is required") }
        return date
    }

    static func values<E: RawRepresentable & CaseIterable>(_ texts: [String], option: String, as _: E.Type) throws(CadenceError) -> [E]
    where E.RawValue == String {
        var out: [E] = []
        for text in texts {
            guard let value = E(rawValue: text) else {
                let valid = E.allCases.map(\.rawValue).joined(separator: ", ")
                throw .validation("--\(option): '\(text)' is not valid; use one of \(valid)")
            }
            out.append(value)
        }
        return out
    }
}

// MARK: - Human formatting

enum Format {
    static func clock(_ timestamp: String?) -> String {
        guard let timestamp, timestamp.count >= 16 else { return "-" }
        let start = timestamp.index(timestamp.startIndex, offsetBy: 11)
        let end = timestamp.index(start, offsetBy: 5)
        return String(timestamp[start..<end])
    }

    static func weekday(_ date: LocalDate) -> String {
        switch date.weekday {
        case .mon: "Monday"
        case .tue: "Tuesday"
        case .wed: "Wednesday"
        case .thu: "Thursday"
        case .fri: "Friday"
        case .sat: "Saturday"
        case .sun: "Sunday"
        }
    }

    static func kind(_ kind: DayKind) -> String {
        switch kind {
        case .workday: "workday"
        case .weekend: "weekend"
        case .holiday: "holiday"
        case .leavePlanned: "planned leave"
        case .leaveUnplanned: "unplanned leave"
        }
    }

    static func ticket(_ ticket: Ticket?, unlessIn title: String = "") -> String {
        guard let ticket, !title.contains(ticket.key) else { return "" }
        return " " + ticket.key
    }

    static func entryLine(_ entry: Entry) -> String {
        var line = "\(clock(entry.occurredAt))  \(entry.kind.rawValue)  \(entry.title)\(ticket(entry.ticket, unlessIn: entry.title))"
        if entry.status != .accepted { line += " (\(entry.status.rawValue))" }
        if entry.quantity > 1 { line += " x\(entry.quantity)" }
        if let seconds = entry.durationS { line += " \(duration(seconds))" }
        return line + "  [\(entry.id)]"
    }

    static func duration(_ seconds: Int64) -> String {
        let minutes = seconds / 60
        return minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
    }

    static func taskLine(_ task: PlanTask) -> String {
        var line = "\(task.position). \(task.title)\(ticket(task.ticket, unlessIn: task.title))"
        if let estimate = task.estimateMin { line += " (\(estimate)m)" }
        line += "  \(task.status.rawValue)"
        if let reason = task.reason { line += ": \(reason)" }
        return line + "  [\(task.id)]"
    }

    static func planSummary(_ tasks: [PlanTask]) -> String {
        guard !tasks.isEmpty else { return "No plan" }
        let done = tasks.filter { $0.status == .done }.count
        return "Plan: \(done) of \(tasks.count) done"
    }

    /// Left-aligned columns, two spaces apart. The last column is not padded.
    static func table(_ rows: [[String]]) -> String {
        guard let width = rows.map(\.count).max() else { return "" }
        var widths = [Int](repeating: 0, count: width)
        for row in rows { for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) } }
        return rows.map { row in
            row.enumerated().map { i, cell in
                i == row.count - 1 ? cell : cell + String(repeating: " ", count: widths[i] - cell.count)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
