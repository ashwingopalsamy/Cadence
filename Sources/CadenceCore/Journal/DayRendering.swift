import Foundation

/// A day as plain text and as JSON, shared by the CLI and the MCP server.
public enum DayRendering {
    public static func json(_ view: DayView) -> JSONValue {
        let presence = view.presence.map { span -> JSONValue in
            ["start": .string(span.start), "end": .string(span.end), "source": .string(span.source.rawValue)]
        }
        return [
            "day": view.day.json, "tasks": .array(view.tasks.map(\.viewJSON)), "entries": .array(view.entries.map(\.json)),
            "presence": .array(presence),
        ]
    }

    public static func human(_ view: DayView) -> String {
        let day = view.day
        var lines: [String] = []
        if let date = LocalDate(day.date) {
            lines.append("\(Format.weekday(date)) \(day.date), \(Format.kind(day.kind))" + (day.label.map { ": \($0)" } ?? ""))
        } else {
            lines.append("\(day.date), \(Format.kind(day.kind))")
        }
        lines.append("First activity \(Format.clock(day.firstActivity)), last activity \(Format.clock(day.lastActivity))")
        if let focus = day.focus { lines.append("Focus: \(focus)") }
        lines.append("")
        lines.append(Format.planSummary(view.tasks))
        lines += view.tasks.map { "  " + Format.taskLine($0) }
        lines.append("")
        lines.append(view.entries.isEmpty ? "No entries" : "Entries: \(view.entries.count)")
        lines += view.entries.map { "  " + Format.entryLine($0) }
        if !view.presence.isEmpty {
            lines.append("")
            lines.append("Presence")
            lines += view.presence.map { "  \(Format.clock($0.start)) to \(Format.clock($0.end)), \($0.source.rawValue)" }
        }
        if day.sealedAt != nil { lines.append("\nSealed \(Format.clock(day.sealedAt))") }
        return lines.joined(separator: "\n")
    }
}
