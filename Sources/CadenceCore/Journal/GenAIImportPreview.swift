import Foundation

/// What `cadence import genai --dry-run` shows (docs/SPEC.md section 10.6): the mapped usage per day, set beside
/// what the ledger already holds from other sources. It reads; it never writes.
public struct GenAIImportPreview: Sendable, Equatable {
    public struct Day: Sendable, Equatable {
        public var day: LocalDate
        public var tool: String
        public var requests: Int64?
        public var outputTokens: Int64?
        public var costMicros: Int64?
        public var estimated: Bool
        /// Other sources already in the ledger for this day and tool.
        public var others: [GenAIOtherSource]
        /// The declared day kind, such as "holiday", when one is declared and is not a plain workday.
        public var kind: DayKind?
    }

    public var mapName: String
    public var input: String
    public var rows: Int
    public var days: [Day]
    public var skipped: [String]

    public var tools: [String] { Array(Set(days.map(\.tool))).sorted() }

    /// Reads the usage records of a mapped envelope.
    /// - Parameters:
    ///   - existing: every source's figures already in the ledger for the range.
    ///   - ownSource: the source the import would write (`import:<name>`), left out of "other sources".
    ///   - declared: the declared kind of a day, if any.
    public init(
        map: MapFile, output: MapOutput, existing: [GenAISourceDay], ownSource: String, declared: (LocalDate) -> DayKind?
    ) {
        mapName = map.name
        input = map.input.rawValue
        rows = output.records
        skipped = output.skipped
        var grouped: [String: GenAISourceDay] = [:]
        var order: [String] = []
        for line in output.envelope.split(separator: 0x0A, omittingEmptySubsequences: true).dropFirst() {
            guard let value = try? JSONParser.parse(bytes: Array(line)), value["type"]?.stringValue == "genai.usage",
                let day = value["day"]?.stringValue.flatMap({ LocalDate($0) }), let tool = value["tool"]?.stringValue
            else { continue }
            let tokens = value["tokens"]
            let model = GenAIModelRow(
                model: value["model"]?.stringValue ?? "*", requests: value["requests"]?.intValue,
                tokens: TokenCounts(
                    input: tokens?["in"]?.intValue, output: tokens?["out"]?.intValue,
                    cacheRead: tokens?["cache_read"]?.intValue, cacheWrite: tokens?["cache_write"]?.intValue),
                costMicros: value["cost_micros"]?.intValue, estimated: value["estimated"]?.boolValue ?? false)
            let key = "\(day)\u{0}\(tool)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: GenAISourceDay(day: day, tool: tool, source: ownSource, models: [])].models.append(model)
        }
        days = order.compactMap { grouped[$0] }.sorted { ($0.day, $0.tool) < ($1.day, $1.tool) }.map { mine in
            let value = mine.tokens.output
            let others = existing.filter { $0.day == mine.day && $0.tool == mine.tool && $0.source != ownSource }
                .sorted { $0.source < $1.source }.map { other in
                    GenAIOtherSource(
                        source: other.source, outputTokens: other.tokens.output,
                        apartTenthsPercent: GenAIPick.apartTenthsPercent(chosen: value, other: other.tokens.output),
                        mismatch: GenAIPick.isMismatch(chosen: value, other: other.tokens.output))
                }
            let kind = declared(mine.day).flatMap { $0 == .workday ? nil : $0 }
            return Day(
                day: mine.day, tool: mine.tool, requests: mine.requests, outputTokens: value, costMicros: mine.costMicros,
                estimated: mine.estimated, others: others, kind: kind)
        }
    }

    // MARK: text

    /// Whole number with thousands separators.
    public static func grouped(_ value: Int64) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (i, c) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (value < 0 ? "-" : "") + String(out.reversed())
    }

    /// `$x.yy` from micro-dollars, in integer arithmetic, rounded half away from zero to the cent.
    public static func dollars(micros: Int64, estimated: Bool = false) -> String {
        let cents = (micros.magnitude + 5000) / 10_000
        let whole = grouped(Int64(cents / 100))
        let fraction = cents % 100
        return (estimated ? "~" : "") + (micros < 0 && cents > 0 ? "-" : "") + "$\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    static func tenths(_ value: Int64) -> String { "\(value / 10).\(value % 10)" }

    func otherText(_ day: Day) -> String {
        if day.others.isEmpty { return "none" }
        return day.others.map { other in
            guard let out = other.outputTokens else { return "\(other.source) unknown" }
            var text = "\(other.source) \(Self.grouped(out))"
            if let apart = other.apartTenthsPercent {
                text += " (\(Self.tenths(apart))% apart\(other.mismatch ? ", mismatch" : ""))"
            } else if other.mismatch {
                text += " (mismatch)"
            }
            return text
        }.joined(separator: ", ")
    }

    /// The table of docs/SPEC.md section 10.6, then skipped rows. "-" marks a figure the file does not give.
    public func text(dryRun: Bool) -> String {
        let noun = input == "csv" ? "rows" : "records"
        let toolText = tools.isEmpty ? "none" : tools.joined(separator: ", ")
        let dayCount = Set(days.map(\.day)).count
        var lines = ["map \(mapName) (map/1, \(input)) \u{00B7} \(rows) \(noun) \u{2192} \(dayCount) days \u{00B7} tool \(toolText)"]
        let multi = tools.count > 1
        func figure(_ v: Int64?) -> String { v.map(Self.grouped) ?? "-" }
        var cells: [[String]] = []
        for d in days {
            let cost = d.costMicros.map { Self.dollars(micros: $0, estimated: d.estimated) } ?? "-"
            var other = otherText(d)
            if let kind = d.kind { other += "  " + kind.rawValue.replacingOccurrences(of: "_", with: " ") }
            cells.append([multi ? "\(d.day) \(d.tool)" : d.day.description, figure(d.requests), figure(d.outputTokens), cost, other])
        }
        func total(_ values: [Int64?]) -> Int64? { GenAIPick.sum(values) }
        let totalCost = total(days.map(\.costMicros)).map { Self.dollars(micros: $0, estimated: days.contains { $0.estimated }) } ?? "-"
        let footer = ["total", figure(total(days.map(\.requests))), figure(total(days.map(\.outputTokens))), totalCost, ""]
        let header = ["day", "requests", "tokens out", "cost", "other sources"]
        let all = [header] + cells + [footer]
        let widths = (0..<4).map { c in all.map { $0[c].count }.max() ?? 0 }
        func line(_ row: [String]) -> String {
            var parts: [String] = []
            for c in 0..<4 {
                let pad = String(repeating: " ", count: widths[c] - row[c].count)
                parts.append(c == 1 || c == 2 ? pad + row[c] : row[c] + pad)
            }
            return (parts.joined(separator: "   ") + "   " + row[4]).trimmingCharacters(in: .whitespaces)
        }
        if !days.isEmpty {
            lines.append(line(header))
            lines.append(contentsOf: cells.map(line))
            lines.append(line(footer))
        }
        if !skipped.isEmpty {
            lines.append("skipped \(skipped.count):")
            lines.append(contentsOf: skipped.map { "  \($0)" })
        }
        if dryRun { lines.append("dry run: nothing written. Run again without --dry-run to import.") }
        return lines.joined(separator: "\n")
    }

    public var json: JSONValue {
        func num(_ v: Int64?) -> JSONValue { v.map { .int($0) } ?? .null }
        let rowsJSON: [JSONValue] = days.map { d in
            [
                "day": .string(d.day.description), "tool": .string(d.tool), "requests": num(d.requests),
                "tokens_out": num(d.outputTokens), "cost_micros": num(d.costMicros), "estimated": .bool(d.estimated),
                "day_kind": d.kind.map { .string($0.rawValue) } ?? .null,
                "other_sources": .array(
                    d.others.map {
                        [
                            "source": .string($0.source), "tokens_out": num($0.outputTokens),
                            "apart_tenths_percent": num($0.apartTenthsPercent), "mismatch": .bool($0.mismatch),
                        ]
                    }),
            ]
        }
        return [
            "map": .string(mapName), "input": .string(input), "rows": .int(Int64(rows)), "days": .array(rowsJSON),
            "totals": [
                "requests": num(GenAIPick.sum(days.map(\.requests))), "tokens_out": num(GenAIPick.sum(days.map(\.outputTokens))),
                "cost_micros": num(GenAIPick.sum(days.map(\.costMicros))),
            ],
            "skipped": .array(skipped.map { .string($0) }),
        ]
    }
}
