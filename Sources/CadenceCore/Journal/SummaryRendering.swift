import Foundation

/// A summary as plain text, shared by the CLI and the MCP server.
public enum SummaryRendering {
    /// A count that may be unknown: "-" when there is no data.
    public static func n(_ value: Int?) -> String { value.map(String.init) ?? "-" }

    public static func ratio(_ value: Int?, of total: Int?) -> String {
        guard let value, let total else { return "-" }
        return "\(value) of \(total)"
    }

    public static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

    public static func spread(_ spread: ClockSpread?) -> String {
        guard let spread else { return "-" }
        return "median \(spread.median), from \(spread.earliest) to \(spread.latest) over \(plural(spread.days, "day"))"
    }

    public static func human(_ s: Summary) -> String {
        var headline = "\(s.label.capitalized): "
        if s.label.contains("..") { headline = "" }
        headline += "\(s.from) to \(s.to), \(plural(s.workdays, "workday"))."
        var lines = [headline]

        // The finding first: the one sentence a reader needs.
        var finding: [String] = []
        if let sealed = s.sealedWorkdays { finding.append("sealed \(sealed) of \(s.countedWorkdays) counted workdays") }
        if let merged = s.mergedPRs, merged > 0 { finding.append("merged \(plural(merged, "PR"))") }
        if let reviews = s.reviews, reviews > 0 { finding.append("gave \(plural(reviews, "review"))") }
        if finding.isEmpty, let entries = s.entries { finding.append("logged \(plural(entries, "entry").replacingOccurrences(of: "entrys", with: "entries"))") }
        lines.append(finding.isEmpty ? "No counted data in this range yet." : "You " + finding.joined(separator: ", ") + ".")
        lines.append("")

        var rows: [[String]] = [
            ["Sealed workdays", ratio(s.sealedWorkdays, of: s.sealedWorkdays == nil ? nil : s.countedWorkdays)
                + (s.beforeLedger > 0 ? " (\(s.beforeLedger) before the ledger began)" : "")],
            ["Plan done", ratio(s.planDone, of: s.planTotal)],
            ["PRs merged", s.mergedPRs.map { merged in
                "\(merged) (assigned \(n(s.assignedPRs)), self-initiated \(n(s.selfInitiatedPRs)))"
            } ?? "-"],
            ["Reviews", n(s.reviews)],
            ["Entries", n(s.entries)],
            ["First activity", spread(s.firstActivity)],
            ["Last activity", spread(s.lastActivity)],
            ["AI days", ratio(s.aiDays, of: s.aiDays == nil ? nil : s.aiCountedDays)],
            ["AI sessions", n(s.aiSessions)],
            ["Output tokens", s.outputTokens.map { tokens in
                "\(tokens) from " + s.tokenSources.sorted { $0.key < $1.key }.map { "\($0.key) (\(plural($0.value, "day")))" }.joined(separator: ", ")
            } ?? "-"],
            ["Streak", "\(s.streak.current) now, best \(s.streak.best)"],
        ]
        if let slips = s.slipsByReason {
            let text = slips.isEmpty ? "none" : slips.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            rows.insert(["Plan slips", text], at: 2)
        }
        if let families = s.entriesByFamily {
            let order = Family.allCases.map(\.rawValue)
            let text = order.compactMap { name in families[name].flatMap { $0 > 0 ? "\(name) \($0)" : nil } }.joined(separator: ", ")
            rows.append(["Entries by family", text.isEmpty ? "none" : text])
        }
        lines.append(Format.table(rows))
        lines.append("")
        lines.append("Findings: none yet. A dash means there is no data, which is not the same as zero.")
        return lines.joined(separator: "\n")
    }
}
