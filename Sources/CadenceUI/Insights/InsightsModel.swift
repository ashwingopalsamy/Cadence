// Insights (docs/SPEC.md section 5.4): Week, Month or Cycle as chapters, each with a label, a big number, a claim, a
// comparison and a picture that means it, with its table twin. The figures come from the summary, the weekly series, the
// day shape and the streak, read in one snapshot off the main thread on a fresh read-only connection. Each range is kept
// by the store's `PRAGMA data_version` and the day, so switching ranges is instant and any write elsewhere invalidates it.
import CadenceCore
import Dispatch
import Foundation
import Observation

// MARK: - The figures

public enum InsightsRange: String, CaseIterable, Sendable {
    case week, month, cycle

    public var summaryRange: SummaryRange {
        switch self {
        case .week: .week
        case .month: .month
        case .cycle: .cycle
        }
    }

    /// The segment's word.
    public var title: String {
        switch self {
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        case .cycle: String(localized: "Cycle")
        }
    }

    /// "this week", inside a sentence.
    var phrase: String { String(localized: "this \(rawValue)") }
}

/// What a cached read is good for: the store as of one `data_version`, on one day.
public struct InsightsStamp: Sendable, Hashable {
    public var version: Int64
    public var today: LocalDate

    public init(version: Int64, today: LocalDate) {
        self.version = version
        self.today = today
    }
}

/// Everything one range of Insights shows, read in one snapshot.
public struct InsightsData: Sendable, Equatable {
    public var range: InsightsRange
    /// Nil when the version could not be read; such a read is never cached.
    public var stamp: InsightsStamp?
    public var today: LocalDate
    public var summary: Summary
    /// The same stretch of the period before ("same point last week"), or nil when there is none to compare with.
    public var previous: Summary?
    public var weeks: [WeekPoint]
    public var shape: [WeekdayShape]
    public var days: [ConsistencyFigures.Day]
    public var streak: Streak
    /// Counted workdays over the last year, for "Your patterns are still forming."
    public var workdaysSoFar: Int
}

public enum InsightsLoad: Sendable, Equatable {
    case loading
    case loaded(InsightsData)
    case failed(StoreFailure)
}

/// Reads Insights from wherever the store is. Both calls block on the disk, so the model calls them off the main thread.
public protocol InsightsLoading: Sendable {
    /// The store's change counter and the day, or nil when the store cannot be read.
    func stamp() -> InsightsStamp?
    /// `.loaded` or `.failed`, never `.loading`.
    func load(_ range: InsightsRange) -> InsightsLoad
}

/// Reads Insights through `Journal` on a fresh read-only connection, one per load, as `DayStoreLoader` reads today. The
/// change counter comes from one long-lived connection, because `data_version` only means something on the connection
/// that keeps reading it.
public struct InsightsStoreLoader: InsightsLoading {
    public let location: StoreLocation
    public let clock: any Clock
    private let probe: StoreVersionProbe?

    /// Under this many counted workdays Insights says "Your patterns are still forming." (section 5.4).
    public static let formingWorkdays = 15
    /// How far back the counted workdays are read for that check.
    static let historyDays = 365

    public init(location: StoreLocation, clock: any Clock) {
        self.location = location
        self.clock = clock
        probe = location.databasePath.map { StoreVersionProbe(path: $0) }
    }

    public func stamp() -> InsightsStamp? {
        guard case .found(let roots) = location, let probe, case .version(let version) = probe.read(),
            let config = try? ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0,
            let zone = TimeZone(identifier: config.profile.timezone)
        else { return nil }
        return InsightsStamp(version: version, today: config.dayBoundary.day(of: clock.now(), in: zone))
    }

    public func load(_ range: InsightsRange) -> InsightsLoad {
        guard case .found(let roots) = location else {
            if case .failed(let failure) = location { return .failed(failure) }
            return .failed(StoreFailure(detail: String(localized: "Cadence could not find its store")))
        }
        // The stamp is read first, so a write that lands during the read makes the next check read again.
        let stamp = stamp()
        do {
            return .loaded(try read(roots, range, stamp: stamp))
        } catch {
            return .failed(StoreFailure(error))
        }
    }

    private func read(_ roots: FileRoots, _ range: InsightsRange, stamp: InsightsStamp?) throws(CadenceError) -> InsightsData {
        guard FileManager.default.fileExists(atPath: roots.database.path) else {
            throw .notFound(String(localized: "There is no cadence.db in \(roots.home.path)"))
        }
        let config = try ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0
        let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
        let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, readOnly: true)
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids, actor: .app, writesGenesis: false)
        let today = journal.today()
        let now = clock.now()
        return try store.transactRead { () throws(CadenceError) -> InsightsData in
            let summary = try journal.summary(range.summaryRange)
            var previous: Summary?
            if let before = Self.previous(range, from: summary.from, to: summary.to) {
                let read = try journal.summary(from: before.from, to: before.to)
                previous = read.countedWorkdays > 0 ? read : nil
            }
            return InsightsData(
                range: range, stamp: stamp, today: today, summary: summary, previous: previous,
                weeks: try journal.weeklySeries(from: summary.from, to: summary.to),
                shape: try journal.dayShape(from: summary.from, to: summary.to),
                days: try Self.days(journal, from: summary.from, to: summary.to, beforeLedger: summary.beforeLedger, now: now),
                streak: try journal.streak(),
                workdaysSoFar: try journal.summary(from: today.adding(days: -Self.historyDays), to: today).countedWorkdays)
        }
    }

    /// The same stretch of the period before: last week to the same weekday, last month to the same day of the month.
    /// A cycle has no earlier cycle to read.
    static func previous(_ range: InsightsRange, from: LocalDate, to: LocalDate) -> (from: LocalDate, to: LocalDate)? {
        switch range {
        case .week:
            return (from.adding(days: -7), to.adding(days: -7))
        case .month:
            let last = from.adding(days: -1)
            guard let start = LocalDate(year: last.year, month: last.month, day: 1) else { return nil }
            var end = LocalDate(year: last.year, month: last.month, day: to.day)
            var day = to.day
            while end == nil, day > 1 {
                day -= 1
                end = LocalDate(year: last.year, month: last.month, day: day)
            }
            return end.map { (start, $0) }
        case .cycle:
            return nil
        }
    }

    /// Each day of the range as the calendar shows it, by the rules the summary counts with: a workday sealed within its
    /// grace window is sealed, one whose window closed without a seal is not, one still inside it is open.
    static func days(
        _ journal: Journal, from: LocalDate, to: LocalDate, beforeLedger: Int, now: Date
    ) throws(CadenceError) -> [ConsistencyFigures.Day] {
        let rules = DayRules(config: journal.config)
        var workdays = 0
        var days: [ConsistencyFigures.Day] = []
        for date in LocalDate.range(from, through: to) {
            let view = try journal.dayView(date).day
            guard view.kind == .workday else {
                days.append(.init(date: date, state: .off(view.kind)))
                continue
            }
            workdays += 1
            // The summary counts the workdays before the ledger began; they are the earliest ones.
            if workdays <= beforeLedger {
                days.append(.init(date: date, state: .beforeLedger))
                continue
            }
            let zone = TimeZone(identifier: view.tz) ?? journal.zone
            if let at = view.sealedAt.flatMap({ Timestamp.parse($0) }), rules.sealCounts(at, for: date, in: zone) {
                days.append(.init(date: date, state: .sealed))
            } else if rules.graceClosed(for: date, at: now, in: zone) {
                days.append(.init(date: date, state: .notSealed))
            } else {
                days.append(.init(date: date, state: .open))
            }
        }
        return days
    }
}

// MARK: - The model

/// The range on screen and what was read for it, published on the main actor.
@MainActor @Observable
public final class InsightsModel {
    public private(set) var range: InsightsRange
    public private(set) var load: InsightsLoad
    /// Counts finished reads, so a caller can wait for one.
    public private(set) var reads = 0

    @ObservationIgnored private let loader: any InsightsLoading
    @ObservationIgnored private let cache = InsightsCache()
    @ObservationIgnored private let queue = DispatchQueue(label: "in.ashwingopalsamy.cadence.insights", qos: .userInitiated)

    /// `initial` is a read already made, such as a snapshot's.
    public init(loader: any InsightsLoading, range: InsightsRange = .month, initial: InsightsData? = nil) {
        self.loader = loader
        self.range = range
        if let initial {
            cache.store(initial)
            load = .loaded(initial)
        } else {
            load = .loading
        }
    }

    /// Shows `range` at once from the cache when it has it, then checks the store and reads again if it changed.
    public func select(_ range: InsightsRange) {
        guard range != self.range else { return }
        self.range = range
        load = cache.data(for: range).map { .loaded($0) } ?? .loading
        refresh()
    }

    /// Checks the store for the range on screen. Call when Insights appears and when the store changes; it reads only
    /// when the version or the day moved.
    public func refresh() {
        let range = range
        let loader = loader
        let cache = cache
        let queue = queue
        Task {
            let result = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: Self.fetch(range, loader: loader, cache: cache)) }
            }
            reads += 1
            if self.range == range { load = result }
        }
    }

    /// Drops every cached range, for a change the version cannot see, such as a new configuration.
    public func invalidate() {
        cache.clear()
        refresh()
    }

    /// The cached read when it is still good, otherwise a new read. Runs on the model's queue.
    nonisolated static func fetch(_ range: InsightsRange, loader: any InsightsLoading, cache: InsightsCache) -> InsightsLoad {
        if let stamp = loader.stamp(), let cached = cache.data(for: range), cached.stamp == stamp {
            return .loaded(cached)
        }
        let result = loader.load(range)
        if case .loaded(let data) = result { cache.store(data) }
        return result
    }
}

/// Reads by range, all from one stamp. Storing a read from a newer stamp drops the others, so after a write no range
/// shows numbers from before it.
final class InsightsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [InsightsRange: InsightsData] = [:]

    func data(for range: InsightsRange) -> InsightsData? {
        lock.lock()
        defer { lock.unlock() }
        return entries[range]
    }

    func store(_ data: InsightsData) {
        lock.lock()
        defer { lock.unlock() }
        guard let stamp = data.stamp else { return }
        entries = entries.filter { $0.value.stamp == stamp }
        entries[data.range] = data
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries = [:]
    }
}

// MARK: - The chapters

/// One chapter (section 6.5): label, number, claim, comparison, picture and table.
public struct InsightsChapter: Sendable, Equatable, Identifiable {
    public enum ID: String, Sendable, CaseIterable {
        case plan, streak, consistency, delivery, reviews, beyond, slipped, dayShape, ai
    }

    public enum Chart: Sendable, Equatable {
        case weekBars(WeekBarsFigures)
        case streak(StreakRoadFigures)
        case calendar(ConsistencyFigures)
        case split(SplitFigures)
        case strata(StrataFigures)
        case slips(SlipFigures)
        case dayShape(DayShapeFigures)
        case tiles(CountTileFigures)

        public var figures: any ChartFigures {
            switch self {
            case .weekBars(let f): f
            case .streak(let f): f
            case .calendar(let f): f
            case .split(let f): f
            case .strata(let f): f
            case .slips(let f): f
            case .dayShape(let f): f
            case .tiles(let f): f
            }
        }
    }

    public var id: ID
    public var label: String
    /// The big number, "-" when unknown.
    public var number: String
    /// A small unit after it: "%", "of 20".
    public var unit: String?
    public var claim: String
    public var comparison: String?
    /// Only from three points or more, and it follows the number.
    public var trend: TrendDirection?
    /// Nil when there is nothing to draw.
    public var chart: Chart?
    /// Said in place of the picture when there is none.
    public var note: String?

    public var table: ChartTable? { chart?.figures.table }
}

/// The page for one read: its head, and either the chapters or "Your patterns are still forming."
public struct InsightsPage: Sendable, Equatable {
    public struct Forming: Sendable, Equatable {
        public var workdays: Int
        public var of: Int
    }

    /// "October, 1 - 29 Oct".
    public var label: String
    /// The page's one plain sentence.
    public var title: String
    public var forming: Forming?
    public var chapters: [InsightsChapter]

    public static let formingTitle = String(localized: "Your patterns are still forming.")
    public static let formingClaim = String(localized: "Trends appear after three weeks, because two points are not a pattern.")
    public static let formingComparison = String(localized: "Until then, here is what is already true.")

    /// The page for `data`, or the forming page when there is no store yet.
    public init(_ data: InsightsData?, showsStreak: Bool, locale: Locale) {
        let dates = ChartDates(locale: locale)
        guard let data else {
            label = String(localized: "Insights")
            title = Self.formingTitle
            forming = Forming(workdays: 0, of: InsightsStoreLoader.formingWorkdays)
            chapters = []
            return
        }
        let s = data.summary
        switch data.range {
        case .week: label = String(localized: "Week \(ChartDates.isoWeek(s.from)), \(dates.compactRange(s.from, s.to))")
        case .month: label = "\(dates.month(s.from)), \(dates.compactRange(s.from, s.to))"
        case .cycle: label = String(localized: "Cycle, \(dates.compactRange(s.from, s.to))")
        }
        let streak = Self.streak(data)
        if data.workdaysSoFar < InsightsStoreLoader.formingWorkdays {
            title = Self.formingTitle
            forming = Forming(workdays: data.workdaysSoFar, of: InsightsStoreLoader.formingWorkdays)
            chapters = showsStreak ? [streak] : []
            return
        }
        forming = nil
        title = Self.title(s, range: data.range)
        let builder = ChapterBuilder(data: data, dates: dates)
        chapters = [
            builder.plan(), showsStreak ? streak : nil, builder.consistency(), builder.delivery(), builder.reviews(), builder.beyond(),
            builder.slipped(), builder.dayShape(), builder.ai(),
        ].compactMap { $0 }
    }

    static func streak(_ data: InsightsData) -> InsightsChapter {
        InsightsChapter(
            id: .streak, label: String(localized: "Streak"), number: String(data.streak.current), claim: String(localized: "Workdays sealed in a row."),
            comparison: String(localized: "Days off never break it."), chart: .streak(StreakRoadFigures(data.streak)))
    }

    /// The plan finding's first sentence, else the first finding's, else a plain statement that nothing is recorded.
    static func title(_ s: Summary, range: InsightsRange) -> String {
        let findings = s.findings
        guard let finding = findings.first(where: { $0.kind == .plan }) ?? findings.first else {
            return String(localized: "Nothing recorded \(range.phrase) yet.")
        }
        return firstSentence(finding.text)
    }

    static func firstSentence(_ text: String) -> String {
        guard let end = text.range(of: ". ") else { return text }
        return String(text[..<end.lowerBound]) + "."
    }
}

/// The chapters of section 5.4, in order, from one read. A claim comes from the findings engine where it states the
/// chapter's point; otherwise it is the chapter's own sentence with the figures filled in. Unknown is "-" and is never
/// drawn as zero.
struct ChapterBuilder {
    let data: InsightsData
    let dates: ChartDates

    private var s: Summary { data.summary }
    private var phrase: String { data.range.phrase }

    private func finding(_ kind: FindingKind) -> Finding? { s.findings.first { $0.kind == kind } }

    /// "Same point last week: 12", or nil when there is no earlier stretch to compare with.
    private func compared(_ figure: (Summary) -> String?) -> String? {
        guard let previous = data.previous, let text = figure(previous) else { return nil }
        switch data.range {
        case .week: return String(localized: "Same point last week: \(text)")
        case .month: return String(localized: "Same point in \(dates.month(previous.from)): \(text)")
        case .cycle: return nil
        }
    }

    private var unrecorded: String { String(localized: "Not recorded \(phrase).") }

    func plan() -> InsightsChapter {
        let percent = ChartText.percent(s.planDone, of: s.planTotal)
        let weeks = WeekBarsFigures.plan(data.weeks)
        let claim: String
        if let done = s.planDone, let total = s.planTotal, total > 0 {
            claim = String(localized: "You finished \(done) of the \(ChartText.count(total, String(localized: "task"))) you planned.")
        } else {
            claim = String(localized: "Nothing was planned \(phrase).")
        }
        var comparison = compared { p in ChartText.percent(p.planDone, of: p.planTotal).map { "\($0)%" } }
        var trend: TrendDirection?
        if let rising = finding(.planTrend) {
            comparison = rising.text
            trend = rising.figures.objectValue?["direction"]?.stringValue.flatMap(TrendDirection.init(rawValue:))
        }
        let drawn = weeks.bars.contains { $0.value != nil }
        return InsightsChapter(
            id: .plan, label: String(localized: "Plan"), number: percent.map(String.init) ?? ChartText.unknown, unit: percent == nil ? nil : "%",
            claim: claim, comparison: comparison, trend: trend, chart: drawn ? .weekBars(weeks) : nil,
            note: drawn ? nil : unrecorded)
    }

    func consistency() -> InsightsChapter {
        let calendar = ConsistencyFigures(days: data.days, locale: dates.locale)
        var claim = String(localized: "Days closed \(phrase).")
        let gaps = calendar.notSealed
        if s.sealedWorkdays == nil {
            claim = String(localized: "No workday has closed \(phrase) yet.")
        } else if gaps.isEmpty {
            claim += String(localized: " Every one is sealed.")
        } else if gaps.count == 1, let gap = gaps.first {
            claim += String(localized: " Only \(dates.short(gap)) is not sealed.")
        } else {
            claim += String(localized: " \(gaps.count) are not sealed.")
        }
        return InsightsChapter(
            id: .consistency, label: String(localized: "Consistency"), number: ChartText.value(s.sealedWorkdays),
            unit: s.sealedWorkdays == nil ? nil : String(localized: "of \(s.countedWorkdays)"), claim: claim,
            comparison: compared { p in p.sealedWorkdays.map { String(localized: "\($0) of \(p.countedWorkdays)") } },
            chart: calendar.days.isEmpty ? nil : .calendar(calendar))
    }

    func delivery() -> InsightsChapter {
        let split = SplitFigures(merged: s.mergedPRs, assigned: s.assignedPRs, selfStarted: s.selfInitiatedPRs)
        let claim: String
        if let own = finding(.selfInitiated) {
            claim = own.text
        } else if s.mergedPRs == 0 {
            claim = String(localized: "No PRs merged \(phrase).")
        } else {
            claim = String(localized: "PRs merged, and how many were your own idea.")
        }
        let drawn = (split?.merged ?? 0) > 0
        return InsightsChapter(
            id: .delivery, label: String(localized: "Delivery"), number: ChartText.value(s.mergedPRs), claim: claim,
            comparison: compared { p in p.mergedPRs.map(String.init) }, chart: drawn ? split.map { .split($0) } : nil,
            note: s.mergedPRs == nil ? unrecorded : nil)
    }

    func reviews() -> InsightsChapter {
        let weeks = WeekBarsFigures.reviews(data.weeks)
        let claim = finding(.reviewCadence)?.text ?? (s.reviews == nil ? String(localized: "Reviews given.") : String(localized: "Reviews given \(phrase)."))
        let drawn = weeks.bars.contains { $0.value != nil }
        return InsightsChapter(
            id: .reviews, label: String(localized: "Reviews"), number: ChartText.value(s.reviews), claim: claim,
            comparison: compared { p in p.reviews.map(String.init) }, chart: drawn ? .weekBars(weeks) : nil,
            note: drawn ? nil : unrecorded)
    }

    func beyond() -> InsightsChapter {
        let strata = StrataFigures(kindCounts: s.kindCounts)
        let claim = finding(.presence)?.text ?? String(localized: "Things you did that were never on the plan.")
        return InsightsChapter(
            id: .beyond, label: String(localized: "Beyond the plan"), number: ChartText.value(strata?.total), claim: claim,
            comparison: compared { p in StrataFigures(kindCounts: p.kindCounts).map { String($0.total) } },
            chart: (strata?.total ?? 0) > 0 ? strata.map { .strata($0) } : nil, note: strata == nil ? unrecorded : nil)
    }

    func slipped() -> InsightsChapter {
        let slips = SlipFigures(slipsByReason: s.slipsByReason)
        let claim: String
        if let slips, let top = slips.reasons.first {
            let total = slips.total
            let lead = total == 1 ? String(localized: "The 1 slip") : top.count == total ? String(localized: "All \(total) slips") : String(localized: "\(top.count) of \(total) slips")
            let verb = top.label == String(localized: "No reason given") ? String(localized: "had no reason given") : "\(top.count == 1 ? String(localized: "was") : String(localized: "were")) \(top.label.lowercased())"
            claim = "\(lead) \(verb)."
        } else if slips != nil {
            claim = String(localized: "None slipped.")
        } else {
            claim = String(localized: "Nothing was planned \(phrase).")
        }
        return InsightsChapter(
            id: .slipped, label: String(localized: "Slipped"), number: ChartText.value(slips?.total), claim: claim,
            comparison: compared { p in SlipFigures(slipsByReason: p.slipsByReason).map { String($0.total) } },
            chart: (slips?.total ?? 0) > 0 ? slips.map { .slips($0) } : nil)
    }

    func dayShape() -> InsightsChapter {
        let shape = DayShapeFigures(shape: data.shape, locale: dates.locale)
        return InsightsChapter(
            id: .dayShape, label: String(localized: "Day shape"), number: s.firstActivity?.median ?? ChartText.unknown,
            claim: finding(.dayShape)?.text ?? String(localized: "Your usual start and end."),
            comparison: String(localized: "From workdays only, so days off never move it."), chart: shape.isEmpty ? nil : .dayShape(shape),
            note: shape.isEmpty ? unrecorded : nil)
    }

    func ai() -> InsightsChapter {
        var claim = String(localized: "Claude Code sessions.")
        if let days = s.aiDays, s.aiCountedDays > 0 {
            claim = String(localized: "Claude Code sessions, on \(days) of \(ChartText.count(s.aiCountedDays, String(localized: "workday"))).")
        }
        var comparison: String?
        var assisted: CountTileFigures.Tile?
        if let merges = s.assistedMerges, merges.share.of > 0 {
            let of = merges.share.of
            let marker = merges.unrecorded > 0 ? String(localized: " with a recorded marker") : ""
            let verb = merges.share.value == 1 ? String(localized: "was") : String(localized: "were")
            comparison = String(localized: "\(merges.share.value) of your \(of) merged \(of == 1 ? String(localized: "PR") : String(localized: "PRs"))\(marker) \(verb) AI-assisted.")
            assisted = .init(value: String(localized: "\(merges.share.value) of \(of)"), label: String(localized: "Merged PRs AI-assisted"), family: .ai)
        }
        let tiles = CountTileFigures([
            s.aiSessions.map { .init(value: String($0), label: String(localized: "Claude Code sessions"), family: .ai) },
            s.aiDays.flatMap { days in s.aiCountedDays > 0 ? .init(value: String(localized: "\(days) of \(s.aiCountedDays)"), label: String(localized: "Workdays with AI"), family: .ai) : nil },
            assisted,
        ])
        return InsightsChapter(
            id: .ai, label: String(localized: "AI"), number: ChartText.value(s.aiSessions), claim: claim, comparison: comparison,
            chart: tiles.tiles.isEmpty ? nil : .tiles(tiles), note: tiles.tiles.isEmpty ? unrecorded : nil)
    }
}
