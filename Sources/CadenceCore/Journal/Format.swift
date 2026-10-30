/// Plain-text formatting shared by the CLI and the MCP server, so a day reads the same on both.
public enum Format {
    public static func clock(_ timestamp: String?) -> String {
        guard let timestamp, timestamp.count >= 16 else { return "-" }
        let start = timestamp.index(timestamp.startIndex, offsetBy: 11)
        let end = timestamp.index(start, offsetBy: 5)
        return String(timestamp[start..<end])
    }

    public static func weekday(_ date: LocalDate) -> String {
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

    public static func kind(_ kind: DayKind) -> String {
        switch kind {
        case .workday: "workday"
        case .weekend: "weekend"
        case .holiday: "holiday"
        case .leavePlanned: "planned leave"
        case .leaveUnplanned: "unplanned leave"
        }
    }

    public static func ticket(_ ticket: Ticket?, unlessIn title: String = "") -> String {
        guard let ticket, !title.contains(ticket.key) else { return "" }
        return " " + ticket.key
    }

    public static func entryLine(_ entry: Entry) -> String {
        var line = "\(clock(entry.occurredAt))  \(entry.kind.rawValue)  \(entry.title)\(ticket(entry.ticket, unlessIn: entry.title))"
        if entry.status != .accepted { line += " (\(entry.status.rawValue))" }
        if entry.quantity > 1 { line += " x\(entry.quantity)" }
        if let seconds = entry.durationS { line += " \(duration(seconds))" }
        return line + "  [\(entry.id)]"
    }

    public static func duration(_ seconds: Int64) -> String {
        let minutes = seconds / 60
        return minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
    }

    public static func taskLine(_ task: PlanTask) -> String {
        var line = "\(task.position). \(task.title)\(ticket(task.ticket, unlessIn: task.title))"
        if let estimate = task.estimateMin { line += " (\(estimate)m)" }
        line += "  \(task.status.rawValue)"
        if let reason = task.reason { line += ": \(reason)" }
        return line + "  [\(task.id)]"
    }

    public static func planSummary(_ tasks: [PlanTask]) -> String {
        guard !tasks.isEmpty else { return "No plan" }
        let done = tasks.filter { $0.status == .done }.count
        return "Plan: \(done) of \(tasks.count) done"
    }

    /// Left-aligned columns, two spaces apart. The last column is not padded.
    public static func table(_ rows: [[String]]) -> String {
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
