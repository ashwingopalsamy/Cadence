import Foundation

// The GenAI metrics of docs/SPEC.md section 11.1 that are more than a count, and the sentence a review needs.
// Everything here is pure: the summary and the proof export read rows and hand them in, so both agree. A metric
// with no data is nil (null in JSON), never 0: unknown is not zero.

/// A count out of a total, with its share as a whole percent.
public struct Share: Sendable, Equatable {
    public var value: Int
    public var of: Int

    public init(_ value: Int, of total: Int) {
        self.value = value
        self.of = total
    }

    /// See `GenAIMetrics.percent`. Nil when the total is 0.
    public var percent: Int? { GenAIMetrics.percent(Int64(value), of: Int64(of)) }
}

/// Merged PRs with an AI marker, out of merged PRs (docs/SPEC.md section 11.1).
public struct AssistedMerges: Sendable, Equatable {
    /// Marked PRs out of the merged PRs whose marker was recorded.
    public var share: Share
    /// Merged PRs with no recorded marker. They are in neither number of the share.
    public var unrecorded: Int

    public init(share: Share, unrecorded: Int) {
        self.share = share
        self.unrecorded = unrecorded
    }
}

/// How long Claude Code sessions ran: the median over the sessions that have a start and an end.
public struct SessionLength: Sendable, Equatable {
    public var medianSeconds: Int
    /// Sessions with a usable start and end.
    public var measured: Int
    /// Sessions started in the range, measured or not.
    public var sessions: Int

    public init(medianSeconds: Int, measured: Int, sessions: Int) {
        self.medianSeconds = medianSeconds
        self.measured = measured
        self.sessions = sessions
    }
}

/// Cache read ÷ (input + cache read), over the rows of the daily pick that report both.
public struct CacheReuse: Sendable, Equatable {
    public var cacheRead: Int64
    public var input: Int64
    /// Days each source supplied.
    public var sources: [String: Int]

    public init(cacheRead: Int64, input: Int64, sources: [String: Int]) {
        self.cacheRead = cacheRead
        self.input = input
        self.sources = sources
    }

    /// Input plus cache read, stopping at `Int64.max` instead of trapping on counters read from a file.
    public var total: Int64 { cacheRead.saturatingAdding(input) }

    /// Taken over the exact sum, so counters cut at the limit still give a true share.
    public var percent: Int? { GenAIMetrics.exactPercent(Int128(cacheRead), of: Int128(cacheRead) + Int128(input)) }
}

public struct ModelShare: Sendable, Equatable {
    public var model: String
    public var outputTokens: Int64

    public init(model: String, outputTokens: Int64) {
        self.model = model
        self.outputTokens = outputTokens
    }
}

/// Share of output tokens by model, from the daily pick. Largest first, then by name.
public struct ModelMix: Sendable, Equatable {
    public var models: [ModelShare]
    /// Days each source supplied.
    public var sources: [String: Int]

    public init(models: [ModelShare], sources: [String: Int]) {
        self.models = models
        self.sources = sources
    }

    /// The sum of the models' output tokens, stopping at `Int64.max` instead of trapping.
    public var totalOutputTokens: Int64 { models.reduce(0) { $0.saturatingAdding($1.outputTokens) } }

    /// Taken over the exact sum, so a total cut at the limit still gives each model its true share.
    public func percent(of model: ModelShare) -> Int? {
        GenAIMetrics.exactPercent(Int128(model.outputTokens), of: models.reduce(Int128(0)) { $0 + Int128($1.outputTokens) })
    }
}

public enum GenAIMetrics {
    /// `value` out of `total` as a whole percent, rounded half up. A share that is not all or nothing never
    /// reads as 0 or 100, so "100%" always means every one. Nil when the total is 0 or the figures are out of order.
    public static func percent(_ value: Int64, of total: Int64) -> Int? {
        exactPercent(Int128(value), of: Int128(total))
    }

    /// The same share over 128-bit figures, which cannot overflow for any sum of Int64 counters.
    static func exactPercent(_ value: Int128, of total: Int128) -> Int? {
        guard total > 0, value >= 0, value <= total else { return nil }
        var percent = Int((value * 200 + total) / (total * 2))
        if value < total { percent = min(percent, 99) }
        if value > 0 { percent = max(percent, 1) }
        return percent
    }

    /// The AI marker an entry's attrs record, or nil when none is recorded: unknown is not "not assisted".
    public static func marker(inAttrs text: String?) -> Bool? {
        guard let text, let attrs = try? JSONParser.parse(text), case .bool(let marked)? = attrs["ai_assisted"] else { return nil }
        return marked
    }

    /// `markers` has one entry per merged PR: its recorded marker, or nil. The share leaves out PRs with no
    /// recorded marker and counts them as unrecorded. Nil when there are merged PRs and none has a marker.
    public static func assistedMerges(_ markers: [Bool?]) -> AssistedMerges? {
        let recorded = markers.compactMap { $0 }
        if !markers.isEmpty && recorded.isEmpty { return nil }
        return AssistedMerges(
            share: Share(recorded.filter { $0 }.count, of: recorded.count), unrecorded: markers.count - recorded.count)
    }

    /// Median of end minus start, in whole seconds, over the sessions with a start and an end that do not run
    /// backwards. An even count takes the mean of the middle two, rounded down. Sessions still open are not measured.
    public static func sessionLength(_ sessions: [(started: String?, ended: String?)]) -> SessionLength? {
        var seconds: [Int] = []
        for session in sessions {
            guard let start = session.started.flatMap(Timestamp.parse), let end = session.ended.flatMap(Timestamp.parse) else { continue }
            let length = Int(end.timeIntervalSince(start).rounded())
            if length >= 0 { seconds.append(length) }
        }
        guard !seconds.isEmpty else { return nil }
        seconds.sort()
        let mid = seconds.count / 2
        let median = seconds.count % 2 == 1 ? seconds[mid] : (seconds[mid - 1] + seconds[mid]) / 2
        return SessionLength(medianSeconds: median, measured: seconds.count, sessions: sessions.count)
    }

    /// Over the model rows of the daily pick, one source per day and tool. A row counts only when it reports both
    /// input and cache read and they are not both 0.
    public static func cacheReuse(_ days: [GenAIDay]) -> CacheReuse? {
        var read: Int64 = 0
        var input: Int64 = 0
        var sourceDays: [String: Set<LocalDate>] = [:]
        for day in days {
            for row in day.models {
                guard let i = row.tokens.input, let r = row.tokens.cacheRead, i >= 0, r >= 0, i.saturatingAdding(r) > 0 else {
                    continue
                }
                input = input.saturatingAdding(i)
                read = read.saturatingAdding(r)
                sourceDays[day.source, default: []].insert(day.day)
            }
        }
        guard !sourceDays.isEmpty else { return nil }
        return CacheReuse(cacheRead: read, input: input, sources: sourceDays.mapValues(\.count))
    }

    /// Over the model rows of the daily pick that report output tokens. Nil when they add up to 0.
    public static func modelMix(_ days: [GenAIDay]) -> ModelMix? {
        var tokens: [String: Int64] = [:]
        var sourceDays: [String: Set<LocalDate>] = [:]
        for day in days {
            for row in day.models {
                guard let output = row.tokens.output, output >= 0 else { continue }
                tokens[row.model] = (tokens[row.model] ?? 0).saturatingAdding(output)
                sourceDays[day.source, default: []].insert(day.day)
            }
        }
        let models = tokens.map { ModelShare(model: $0.key, outputTokens: $0.value) }
            .sorted { $0.outputTokens != $1.outputTokens ? $0.outputTokens > $1.outputTokens : $0.model < $1.model }
        let mix = ModelMix(models: models, sources: sourceDays.mapValues(\.count))
        return mix.totalOutputTokens > 0 ? mix : nil
    }

    // MARK: definitions

    /// Shared by the summary and the proof, so a number never has two meanings.
    static let sessionLengthDefinition =
        "Median of end minus start over Claude Code sessions started in the range that have both times; sessions still open, or that end before they start, are not measured"
    static let cacheReuseDefinition =
        "Cache read tokens divided by input plus cache read tokens, over the model rows of the daily pick that report both; one source per day, never summed across sources"
    static let modelMixDefinition =
        "Share of output tokens by model, over the model rows of the daily pick that report output tokens; one source per day, never summed across sources"

    // MARK: JSON

    static func number(_ value: Int?) -> JSONValue { value.map { .int(Int64($0)) } ?? .null }

    /// `value`, `of`, `percent` and `unrecorded` are null when the figure is unknown.
    static func assistedJSON(_ assisted: AssistedMerges?, definition: String) -> JSONValue {
        [
            "value": number(assisted?.share.value), "of": number(assisted?.share.of), "percent": number(assisted?.share.percent),
            "unrecorded": number(assisted?.unrecorded), "definition": .string(definition),
        ]
    }
}

/// "The sentence your review needs" (docs/SPEC.md section 11), for the cycle recap and the proof summary.
public enum ReviewSentence {
    /// What the sentence is, as it appears next to the number.
    static let definition =
        "AI days, AI-assisted merges and agent-logged entries in one sentence, written from the figures beside it and computed by Cadence; the verifier recomputes only merged_prs and reviews. Tokens back it up and are not the headline"

    /// Each clause needs its own figure; one that is unknown is left out, and one that is a known zero is stated.
    /// Nil when no figure is known. Example: "AI on 17 of 19 workdays. 64% of merged PRs were AI-assisted. Your
    /// agent logged 31 entries you accepted."
    public static func make(aiDays: Share?, assisted: AssistedMerges?, agentEntries: Int?) -> String? {
        var sentences: [String] = []
        if let days = aiDays, days.of > 0 {
            sentences.append("AI on \(days.value) of \(days.of) \(days.of == 1 ? "workday" : "workdays").")
        }
        if let assisted, let percent = assisted.share.percent {
            if assisted.unrecorded == 0 {
                sentences.append("\(percent)% of merged PRs were AI-assisted.")
            } else {
                let count = assisted.share.of
                sentences.append(
                    "\(percent)% of the \(count) merged \(count == 1 ? "PR" : "PRs") with a recorded marker \(count == 1 ? "was" : "were") AI-assisted.")
            }
        }
        if let agentEntries {
            sentences.append("Your agent logged \(agentEntries) \(agentEntries == 1 ? "entry" : "entries") you accepted.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
