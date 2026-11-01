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

    static let maxModels = 6

    /// "endpoint (3 days), import (1 day)".
    static func sources(_ days: [String: Int]) -> String {
        days.sorted { $0.key < $1.key }.map { "\($0.key) (\(plural($0.value, "day")))" }.joined(separator: ", ")
    }

    /// "2 of 3 (67%)", with the PRs left out for want of a recorded marker.
    static func assisted(_ assisted: AssistedMerges?) -> String {
        guard let assisted else { return "-" }
        var text = "\(assisted.share.value) of \(assisted.share.of)"
        if let percent = assisted.share.percent { text += " (\(percent)%)" }
        if assisted.unrecorded > 0 { text += ", \(assisted.unrecorded) without a recorded marker" }
        return text
    }

    /// "median 42m over 3 of 5 sessions".
    static func sessionLength(_ length: SessionLength?) -> String {
        guard let length else { return "-" }
        let median = length.medianSeconds < 60 ? "\(length.medianSeconds)s" : Format.duration(Int64(length.medianSeconds))
        return "median \(median) over \(length.measured) of \(plural(length.sessions, "session"))"
    }

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

        // The sentence a review needs, labelled as the spec names it, with what it is built from.
        if let sentence = s.reviewSentence {
            lines.append("The sentence your review needs")
            lines.append(sentence)
            lines.append("Computed by Cadence from the figures below. Tokens back it up and are not the headline.")
        } else {
            lines.append("The sentence your review needs: -")
        }
        lines.append("")

        var rows: [[String]] = [
            ["Sealed workdays", ratio(s.sealedWorkdays, of: s.sealedWorkdays == nil ? nil : s.countedWorkdays)
                + (s.beforeLedger > 0 ? " (\(s.beforeLedger) before the ledger began)" : "")],
            ["Plan done", ratio(s.planDone, of: s.planTotal)
                + (s.planAfterSeal.map { $0 > 0 ? " (\($0) added after wrap-up \($0 == 1 ? "is" : "are") not counted)" : "" } ?? "")],
            ["PRs merged", s.mergedPRs.map { merged in
                "\(merged) (assigned \(n(s.assignedPRs)), self-initiated \(n(s.selfInitiatedPRs)))"
            } ?? "-"],
            ["Reviews", n(s.reviews)],
            ["Entries", n(s.entries)],
            ["First activity", spread(s.firstActivity)],
            ["Last activity", spread(s.lastActivity)],
            ["AI days", ratio(s.aiDays, of: s.aiDays == nil ? nil : s.aiCountedDays)],
            ["AI-assisted merges", assisted(s.assistedMerges)],
            ["Agent-logged entries", n(s.agentEntries)],
            ["AI sessions", n(s.aiSessions)],
            ["AI session length", sessionLength(s.sessionLength)],
            ["Output tokens", s.outputTokens.map { tokens in
                "\(tokens) from " + sources(s.tokenSources)
            } ?? "-"],
            ["Cache reuse", s.cacheReuse.flatMap { reuse in
                reuse.percent.map { percent in
                    "\(percent)% (\(reuse.cacheRead) cache read of \(reuse.total) input and cache read tokens) from "
                        + sources(reuse.sources)
                }
            } ?? "-"],
            ["Model mix", s.modelMix.map { mix in
                let shown = mix.models.prefix(maxModels).map { share in
                    "\(share.model == "*" ? "unknown model" : share.model) \(mix.percent(of: share).map { "\($0)%" } ?? "-")"
                }
                let more = mix.models.count > maxModels ? ", and \(mix.models.count - maxModels) more" : ""
                return shown.joined(separator: ", ") + more + " of output tokens"
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
