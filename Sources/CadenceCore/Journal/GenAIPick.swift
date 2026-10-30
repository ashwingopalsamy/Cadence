import Foundation

// The GenAI daily pick (docs/SPEC.md sections 10.6 and 11): for each day and tool, one source is used, chosen by
// `config.genai.priority`, and sources are never summed. The others stay visible, with a mismatch flag.

/// One model's figures from one source on one day. A nil counter is unknown, not zero.
public struct GenAIModelRow: Sendable, Equatable {
    public var model: String
    public var requests: Int64?
    public var tokens: TokenCounts
    public var costMicros: Int64?
    /// The cost was computed from a price table. Read from the row's last `genai.usage` event.
    public var estimated: Bool

    public init(model: String, requests: Int64?, tokens: TokenCounts, costMicros: Int64?, estimated: Bool) {
        self.model = model
        self.requests = requests
        self.tokens = tokens
        self.costMicros = costMicros
        self.estimated = estimated
    }
}

/// Everything one source says about one tool on one day: its rows per model and their totals.
public struct GenAISourceDay: Sendable, Equatable {
    public var day: LocalDate
    public var tool: String
    public var source: String
    /// Sorted by model.
    public var models: [GenAIModelRow]

    public init(day: LocalDate, tool: String, source: String, models: [GenAIModelRow]) {
        self.day = day
        self.tool = tool
        self.source = source
        self.models = models.sorted { $0.model < $1.model }
    }

    /// Sum over models; nil when no model knows the counter.
    public var requests: Int64? { GenAIPick.sum(models.map(\.requests)) }
    public var tokens: TokenCounts {
        TokenCounts(
            input: GenAIPick.sum(models.map(\.tokens.input)), output: GenAIPick.sum(models.map(\.tokens.output)),
            cacheRead: GenAIPick.sum(models.map(\.tokens.cacheRead)), cacheWrite: GenAIPick.sum(models.map(\.tokens.cacheWrite)))
    }
    public var costMicros: Int64? { GenAIPick.sum(models.map(\.costMicros)) }
    /// True when any model's cost is estimated.
    public var estimated: Bool { models.contains { $0.estimated && $0.costMicros != nil } }
}

/// A source that was not used for a day, with how far its output tokens are from the chosen source's.
public struct GenAIOtherSource: Sendable, Equatable {
    public var source: String
    public var outputTokens: Int64?
    /// Distance from the chosen source's output tokens, relative to the chosen value, in tenths of a percent
    /// (rounded half up). Nil when either value is unknown or the chosen value is 0.
    public var apartTenthsPercent: Int64?
    /// More than 15% apart (see `GenAIPick.isMismatch`).
    public var mismatch: Bool
}

/// The pick for one day and tool.
public struct GenAIDay: Sendable, Equatable {
    public var day: LocalDate
    public var tool: String
    /// The chosen source, as stored on its rows.
    public var source: String
    public var chosen: GenAISourceDay
    /// Per-model rows of the chosen source.
    public var models: [GenAIModelRow] { chosen.models }
    public var requests: Int64? { chosen.requests }
    public var tokens: TokenCounts { chosen.tokens }
    public var costMicros: Int64? { chosen.costMicros }
    public var estimated: Bool { chosen.estimated }
    /// The other sources, sorted by name.
    public var others: [GenAIOtherSource]
    /// Any other source's output tokens are more than 15% from the chosen one's.
    public var mismatch: Bool { others.contains { $0.mismatch } }
}

public enum GenAIPick {
    /// Relative difference, in percent of the chosen value, above which two sources disagree.
    public static let mismatchPercent: Int64 = 15

    /// Sum of the known values; nil when none is known. A sum past the range of Int64 stops at the limit instead of
    /// trapping, since counters read from a file can be as large as 2^53 - 1 and a day can hold many rows.
    static func sum(_ values: [Int64?]) -> Int64? {
        let known = values.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        return known.reduce(0) { $0.saturatingAdding($1) }
    }

    /// "import" for `import:*`; "transcripts" for a configured collector whose builtin is
    /// claude-code-transcripts; "endpoint" for any other configured command or map collector; nil otherwise.
    public static func category(of source: String, collectors: [Config.Collector]) -> String? {
        if source.hasPrefix("import:") { return "import" }
        guard let collector = collectors.first(where: { $0.name == source }) else { return nil }
        if collector.builtin == "claude-code-transcripts" { return "transcripts" }
        return collector.builtin == nil ? "endpoint" : nil
    }

    /// Position of a source in the priority list: an exact name match wins over a category match; a source
    /// that matches nothing comes after every listed one.
    public static func rank(of source: String, priority: [String], collectors: [Config.Collector]) -> Int {
        if let exact = priority.firstIndex(of: source) { return exact }
        if let category = category(of: source, collectors: collectors), let index = priority.firstIndex(of: category) {
            return index
        }
        return priority.count
    }

    /// Whether `other` output tokens are more than 15% away from the `chosen` value, relative to the chosen one.
    /// Exactly 15% is not a mismatch. A chosen value of 0 makes any non-zero other value a mismatch. Either
    /// value unknown is not a mismatch (unknown is not zero).
    public static func isMismatch(chosen: Int64?, other: Int64?) -> Bool {
        guard let chosen, let other else { return false }
        // 128-bit arithmetic: two Int64 values are at most 2^64 apart, and 100 times that still fits.
        let diff = distance(chosen, other)
        return chosen == 0 ? diff > 0 : diff * 100 > Int128(mismatchPercent) * Int128(chosen)
    }

    /// Distance in tenths of a percent of the chosen value, rounded half up; nil when it cannot be told. A distance
    /// too large for Int64 stops at `Int64.max`.
    public static func apartTenthsPercent(chosen: Int64?, other: Int64?) -> Int64? {
        guard let chosen, let other, chosen > 0 else { return nil }
        let scaled = (distance(chosen, other) * 2000 + Int128(chosen)) / (Int128(chosen) * 2)
        return scaled > Int128(Int64.max) ? Int64.max : Int64(scaled)
    }

    /// `|a - b|` without overflow, for any two Int64 values.
    private static func distance(_ a: Int64, _ b: Int64) -> Int128 {
        let (x, y) = (Int128(a), Int128(b))
        return x > y ? x - y : y - x
    }

    /// Chooses one source per day and tool. Ties in rank go to the source name that sorts first. Input order
    /// does not matter; the result is sorted by day, then tool.
    public static func pick(_ sourceDays: [GenAISourceDay], config: Config) -> [GenAIDay] {
        var groups: [String: [GenAISourceDay]] = [:]
        for entry in sourceDays { groups["\(entry.day)\u{0}\(entry.tool)", default: []].append(entry) }
        var days: [GenAIDay] = []
        for (_, entries) in groups {
            let ordered = entries.sorted {
                let a = rank(of: $0.source, priority: config.genai.priority, collectors: config.collectors)
                let b = rank(of: $1.source, priority: config.genai.priority, collectors: config.collectors)
                return a != b ? a < b : $0.source < $1.source
            }
            guard let chosen = ordered.first else { continue }
            let value = chosen.tokens.output
            let others = ordered.dropFirst().sorted { $0.source < $1.source }.map { other in
                let out = other.tokens.output
                return GenAIOtherSource(
                    source: other.source, outputTokens: out,
                    apartTenthsPercent: apartTenthsPercent(chosen: value, other: out),
                    mismatch: isMismatch(chosen: value, other: out))
            }
            days.append(GenAIDay(day: chosen.day, tool: chosen.tool, source: chosen.source, chosen: chosen, others: others))
        }
        return days.sorted { $0.day != $1.day ? $0.day < $1.day : $0.tool < $1.tool }
    }
}

extension Journal {
    /// Every source's figures per day and tool in the range, one entry per source. Days with no row are absent.
    public func genaiSourceDays(from: LocalDate, to: LocalDate) throws(CadenceError) -> [GenAISourceDay] {
        var grouped: [String: (LocalDate, String, String, [GenAIModelRow])] = [:]
        let found = try rows(
            "SELECT * FROM genai_usage WHERE day >= ? AND day <= ? ORDER BY day, tool, source, model",
            [.text(from.description), .text(to.description)])
        for row in found {
            guard let dayText = row.text("day"), let day = LocalDate(dayText), let tool = row.text("tool"),
                let source = row.text("source"), let model = row.text("model")
            else { continue }
            // The estimated flag lives only in the ledger: the row's last event says what the row holds.
            let subject = "usage:\(dayText):\(tool):\(model):\(source)"
            let last = try store.events(subject: subject).last
            let estimated = last.flatMap { try? GenAIUsage(json: $0.data) }?.estimated ?? false
            let entry = GenAIModelRow(
                model: model, requests: row.int("requests"),
                tokens: TokenCounts(
                    input: row.int("tokens_in"), output: row.int("tokens_out"), cacheRead: row.int("tokens_cache_read"),
                    cacheWrite: row.int("tokens_cache_write")),
                costMicros: row.int("cost_micros"), estimated: estimated)
            let key = "\(dayText)\u{0}\(tool)\u{0}\(source)"
            grouped[key, default: (day, tool, source, [])].3.append(entry)
        }
        return grouped.values.map { GenAISourceDay(day: $0.0, tool: $0.1, source: $0.2, models: $0.3) }
            .sorted { ($0.day, $0.tool, $0.source) < ($1.day, $1.tool, $1.source) }
    }

    /// The daily pick for the range: one source per day and tool by `config.genai.priority`, never summed.
    public func genaiDays(from: LocalDate, to: LocalDate) throws(CadenceError) -> [GenAIDay] {
        GenAIPick.pick(try genaiSourceDays(from: from, to: to), config: config)
    }
}

extension Int64 {
    /// `self + other`, stopping at `Int64.max` or `Int64.min` instead of trapping.
    func saturatingAdding(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }
}
