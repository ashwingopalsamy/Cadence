import Foundation
import Testing

@testable import CadenceCore

@Suite struct GenAIPickTests {
    static let day = LocalDate("2026-10-28")!

    static func row(_ model: String = "*", out: Int64?, requests: Int64? = nil, cost: Int64? = nil, estimated: Bool = false)
        -> GenAIModelRow
    {
        GenAIModelRow(
            model: model, requests: requests, tokens: TokenCounts(input: nil, output: out, cacheRead: nil, cacheWrite: nil),
            costMicros: cost, estimated: estimated)
    }

    static func source(_ name: String, _ rows: [GenAIModelRow], day: LocalDate = day, tool: String = "claude-code")
        -> GenAISourceDay
    {
        GenAISourceDay(day: day, tool: tool, source: name, models: rows)
    }

    static func config(priority: [String]? = nil, collectors: [Config.Collector] = []) -> Config {
        var config = Config.defaults(timezone: "Asia/Kolkata")
        if let priority { config.genai.priority = priority }
        config.collectors = collectors
        return config
    }

    static let collectors = [
        Config.Collector(name: "usage-api", command: ["/usr/bin/curl"]),
        Config.Collector(name: "mapped", map: "mapped.json"),
        Config.Collector(name: "cc", builtin: "claude-code-transcripts"),
        Config.Collector(name: "github", builtin: "github"),
    ]

    // MARK: categories and priority

    @Test func sourcesMapToCategories() {
        let c = Self.collectors
        #expect(GenAIPick.category(of: "import:october-app", collectors: c) == "import")
        #expect(GenAIPick.category(of: "usage-api", collectors: c) == "endpoint")
        #expect(GenAIPick.category(of: "mapped", collectors: c) == "endpoint")
        #expect(GenAIPick.category(of: "cc", collectors: c) == "transcripts")
        #expect(GenAIPick.category(of: "github", collectors: c) == nil)
        #expect(GenAIPick.category(of: "unknown", collectors: c) == nil)
    }

    @Test func theDefaultPriorityIsEndpointThenTranscriptsThenImport() {
        let config = Self.config(collectors: Self.collectors)
        let all = [
            Self.source("import:october-app", [Self.row(out: 100)]), Self.source("cc", [Self.row(out: 200)]),
            Self.source("usage-api", [Self.row(out: 300)]),
        ]
        #expect(GenAIPick.pick(all, config: config).first?.source == "usage-api")
        #expect(GenAIPick.pick(Array(all.dropLast()), config: config).first?.source == "cc")
        #expect(GenAIPick.pick(Array(all.dropLast(2)), config: config).first?.source == "import:october-app")
    }

    @Test func aChangedPriorityChangesTheWinner() {
        let config = Self.config(priority: ["import", "transcripts", "endpoint"], collectors: Self.collectors)
        let all = [Self.source("usage-api", [Self.row(out: 300)]), Self.source("import:october-app", [Self.row(out: 100)])]
        #expect(GenAIPick.pick(all, config: config).first?.source == "import:october-app")
    }

    @Test func anExactSourceNameBeatsItsCategory() {
        // usage-api is an endpoint, but the list names it second, after the import category.
        let config = Self.config(priority: ["import", "usage-api"], collectors: Self.collectors)
        let all = [Self.source("usage-api", [Self.row(out: 300)]), Self.source("import:x", [Self.row(out: 100)])]
        #expect(GenAIPick.pick(all, config: config).first?.source == "import:x")
        // An exact name for the import wins over the category rank of another source.
        let exact = Self.config(priority: ["endpoint", "import:x", "import"], collectors: Self.collectors)
        let two = [Self.source("import:x", [Self.row(out: 1)]), Self.source("import:y", [Self.row(out: 2)])]
        #expect(GenAIPick.pick(two, config: exact).first?.source == "import:x")
    }

    @Test func aSourceOutsideThePriorityComesLastAndTiesGoToTheFirstName() {
        let config = Self.config(collectors: Self.collectors)
        let all = [Self.source("zzz", [Self.row(out: 1)]), Self.source("aaa", [Self.row(out: 2)]), Self.source("import:b", [Self.row(out: 3)])]
        #expect(GenAIPick.pick(all, config: config).first?.source == "import:b")
        let rest = [Self.source("zzz", [Self.row(out: 1)]), Self.source("aaa", [Self.row(out: 2)])]
        #expect(GenAIPick.pick(rest, config: config).first?.source == "aaa")
    }

    // MARK: totals

    @Test func totalsSumModelsOfTheChosenSourceOnlyAndNeverAcrossSources() throws {
        let config = Self.config(collectors: Self.collectors)
        let all = [
            Self.source(
                "usage-api",
                [
                    Self.row("model-a", out: 1000, requests: 10, cost: 1_500_000),
                    Self.row("model-b", out: 500, requests: 5, cost: 250_000, estimated: true),
                ]),
            Self.source("cc", [Self.row(out: 1500, requests: 99, cost: 9_000_000)]),
        ]
        let pick = try #require(GenAIPick.pick(all, config: config).first)
        #expect(pick.source == "usage-api")
        #expect(pick.tokens.output == 1500 && pick.requests == 15 && pick.costMicros == 1_750_000)
        #expect(pick.estimated)
        #expect(pick.models.map(\.model) == ["model-a", "model-b"])
        #expect(pick.others == [GenAIOtherSource(source: "cc", outputTokens: 1500, apartTenthsPercent: 0, mismatch: false)])
    }

    @Test func nullCountersStayNull() throws {
        let config = Self.config(collectors: Self.collectors)
        let pick = try #require(GenAIPick.pick([Self.source("usage-api", [Self.row(out: nil)])], config: config).first)
        #expect(pick.tokens == TokenCounts() && pick.requests == nil && pick.costMicros == nil && !pick.estimated)
        // A known value next to an unknown one sums the known; the unknown model adds nothing.
        let mixed = try #require(
            GenAIPick.pick([Self.source("usage-api", [Self.row("a", out: nil), Self.row("b", out: 7)])], config: config).first)
        #expect(mixed.tokens.output == 7)
    }

    @Test func aDayWithNoRowsIsAbsentAndDaysAndToolsAreKeptApart() {
        let config = Self.config(collectors: Self.collectors)
        let d1 = LocalDate("2026-10-27")!
        let d3 = LocalDate("2026-10-29")!
        let all = [
            Self.source("usage-api", [Self.row(out: 1)], day: d3), Self.source("usage-api", [Self.row(out: 2)], day: d1),
            Self.source("cc", [Self.row(out: 3)], day: d1, tool: "other-tool"),
        ]
        let picks = GenAIPick.pick(all, config: config)
        #expect(picks.map(\.day) == [d1, d1, d3])
        #expect(picks.map(\.tool) == ["claude-code", "other-tool", "claude-code"])
        #expect(!picks.contains { $0.day == Self.day })
    }

    // MARK: mismatch

    @Test func mismatchIsMoreThanFifteenPercentOfTheChosenValue() {
        #expect(!GenAIPick.isMismatch(chosen: 1000, other: 1150))  // exactly 15%
        #expect(!GenAIPick.isMismatch(chosen: 1000, other: 850))
        #expect(GenAIPick.isMismatch(chosen: 1000, other: 1151))
        #expect(GenAIPick.isMismatch(chosen: 1000, other: 849))
        #expect(!GenAIPick.isMismatch(chosen: 1000, other: 1000))
        #expect(!GenAIPick.isMismatch(chosen: 0, other: 0))
        #expect(GenAIPick.isMismatch(chosen: 0, other: 1))
        #expect(!GenAIPick.isMismatch(chosen: nil, other: 5))
        #expect(!GenAIPick.isMismatch(chosen: 5, other: nil))
        #expect(GenAIPick.apartTenthsPercent(chosen: 96115, other: 95880) == 2)  // 0.2% apart
        #expect(GenAIPick.apartTenthsPercent(chosen: 0, other: 5) == nil)
        #expect(GenAIPick.apartTenthsPercent(chosen: 1000, other: nil) == nil)
    }

    // Counters read from a file can reach 2^53 - 1, so the distance arithmetic must not wrap or trap.
    @Test func hugeCountersNeitherTrapNorWrap() {
        let big: Int64 = 9_007_199_254_740_991
        #expect(GenAIPick.apartTenthsPercent(chosen: 1, other: big) == (big - 1) * 1000)
        #expect(GenAIPick.isMismatch(chosen: 1, other: big))
        #expect(GenAIPick.apartTenthsPercent(chosen: big, other: 1) == 1000)  // 100.0% apart
        #expect(GenAIPick.isMismatch(chosen: big, other: 1))
        #expect(!GenAIPick.isMismatch(chosen: big, other: big))
        #expect(GenAIPick.apartTenthsPercent(chosen: big, other: big) == 0)
        // 15% of the largest safe integer, to the digit.
        let edge = big / 20 * 20  // divisible by 20, so 15% is exact
        #expect(!GenAIPick.isMismatch(chosen: edge, other: edge + edge / 20 * 3))
        #expect(GenAIPick.isMismatch(chosen: edge, other: edge + edge / 20 * 3 + 1))
        // Whole Int64 range: a result that would not fit saturates instead of trapping.
        #expect(GenAIPick.apartTenthsPercent(chosen: 1, other: Int64.max) == Int64.max)
        #expect(GenAIPick.isMismatch(chosen: 1, other: Int64.max))
        #expect(GenAIPick.isMismatch(chosen: Int64.max, other: Int64.min))
        #expect(GenAIPick.isMismatch(chosen: Int64.min, other: Int64.max))
        #expect(GenAIPick.apartTenthsPercent(chosen: Int64.max, other: Int64.min) == 2000)
        #expect(GenAIPick.apartTenthsPercent(chosen: Int64.min, other: 5) == nil)
    }

    @Test func aPickBetweenTwoHugeSourcesKeepsBothFigures() {
        let big: Int64 = 9_007_199_254_740_991
        let config = Self.config(collectors: Self.collectors)
        let days = GenAIPick.pick(
            [Self.source("usage-api", [Self.row(out: 1)]), Self.source("cc", [Self.row(out: big)])], config: config)
        #expect(days.count == 1 && days[0].source == "usage-api")
        #expect(days[0].others.first?.outputTokens == big)
        #expect(days[0].others.first?.apartTenthsPercent == (big - 1) * 1000)
        #expect(days[0].mismatch)
    }

    @Test func sumsOfHugeCountersSaturate() {
        let big: Int64 = 9_007_199_254_740_991
        let rows = (0..<2000).map { Self.row("m\($0)", out: big) }
        let source = Self.source("usage-api", rows)
        #expect(source.tokens.output == Int64.max)
        #expect(Self.source("usage-api", [Self.row("a", out: 5), Self.row("b", out: 7)]).tokens.output == 12)
    }

    @Test func aDayCarriesTheMismatchFlagWhenAnyOtherSourceDisagrees() throws {
        let config = Self.config(collectors: Self.collectors)
        let all = [
            Self.source("usage-api", [Self.row(out: 1000)]), Self.source("cc", [Self.row(out: 1100)]),
            Self.source("import:x", [Self.row(out: 2000)]),
        ]
        let pick = try #require(GenAIPick.pick(all, config: config).first)
        #expect(pick.mismatch)
        #expect(pick.others.map(\.source) == ["cc", "import:x"])
        #expect(pick.others.map(\.mismatch) == [false, true])
        #expect(pick.others[0].apartTenthsPercent == 100)
    }

    // MARK: through the journal

    @Test func journalReadsRowsAndTheEstimatedFlagFromTheLedger() throws {
        let (journal, store, _) = try SummaryTests.journal()
        func usage(_ source: String, _ model: String, out: Int64?, estimated: Bool = false, cost: Int64? = nil) -> EventDraft {
            EventPayload.genaiUsage(GenAIUsage(
                day: "2026-10-28", tool: "claude-code", model: model, source: source, sessions: nil, requests: 3,
                tokens: TokenCounts(input: 10, output: out, cacheRead: nil, cacheWrite: 4), costMicros: cost, estimated: estimated))
                .draft(actor: .collector("usage-api"))
        }
        try store.append([
            usage("usage-api", "model-a", out: 100, estimated: true, cost: 5), usage("usage-api", "model-b", out: 50, cost: 7),
            usage("transcripts", "model-a", out: 120),
        ])
        let days = try journal.genaiDays(from: LocalDate("2026-10-01")!, to: LocalDate("2026-10-30")!)
        #expect(days.count == 1)
        let pick = days[0]
        // No collector is configured, so "usage-api" matches nothing and "transcripts" matches its entry exactly.
        #expect(pick.source == "transcripts" && pick.others.map(\.source) == ["usage-api"])
        let byName = Dictionary(uniqueKeysWithValues: try journal.genaiSourceDays(from: pick.day, to: pick.day).map { ($0.source, $0) })
        #expect(byName["usage-api"]?.estimated == true && byName["usage-api"]?.tokens.output == 150)
        #expect(byName["usage-api"]?.tokens.cacheWrite == 8 && byName["usage-api"]?.tokens.cacheRead == nil)
        #expect(byName["transcripts"]?.estimated == false && byName["transcripts"]?.costMicros == nil)
        let none = try journal.genaiDays(from: LocalDate("2026-10-29")!, to: LocalDate("2026-10-30")!)
        #expect(none.isEmpty)
    }
}
