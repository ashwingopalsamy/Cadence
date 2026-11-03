import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// Insights (docs/SPEC.md section 5.4) read from the October demo seed in a temporary store.
@MainActor @Suite struct InsightsTests {
    static let gb = Locale(identifier: "en_GB")

    /// A home holding the seeded store, removed by `remove()`.
    struct Home {
        let roots: FileRoots

        init(seeded: Bool = true) throws {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cadence-insights-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            roots = FileRoots(home: folder)
            try ConfigStore.save(DemoSeed.config(), to: roots.config)
            let clock = ManualClock(Timestamp.parse(DemoSeed.startInstant)!)
            let journal = try Self.journal(roots, clock)
            if seeded { try DemoSeed.seed(into: journal, clock: clock) }
        }

        static func journal(_ roots: FileRoots, _ clock: ManualClock) throws -> Journal {
            let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1))
            let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
            return try Journal(store: store, config: DemoSeed.config(), clock: clock, ids: ids)
        }

        func loader(_ instant: String) -> InsightsStoreLoader {
            InsightsStoreLoader(location: .found(roots), clock: ManualClock(Timestamp.parse(instant)!))
        }

        func remove() { try? FileManager.default.removeItem(at: roots.home) }
    }

    /// Thursday 29 October, 19:00 in Kolkata, after that day's seal.
    static let thursday = "2026-10-29T13:30:00Z"
    /// Friday 9 October, noon in Kolkata.
    static let friday = "2026-10-09T06:30:00Z"

    static func data(_ load: InsightsLoad) throws -> InsightsData {
        guard case .loaded(let data) = load else { throw CadenceError.integrity("expected Insights to load, got \(load)") }
        return data
    }

    // MARK: the chapters from the seed

    @Test func theMonthReadsAsTheChaptersOfTheSpecInOrder() throws {
        let home = try Home()
        defer { home.remove() }
        let data = try Self.data(home.loader(Self.thursday).load(.month))
        #expect(data.summary.from == LocalDate("2026-10-01"))
        #expect(data.workdaysSoFar >= InsightsStoreLoader.formingWorkdays)
        let page = InsightsPage(data, showsStreak: true, locale: Self.gb)
        #expect(page.forming == nil)
        #expect(page.label == "October, 1 - 29 Oct")
        #expect(page.title == "84% of your plan got done.")
        #expect(page.chapters.map(\.id) == InsightsChapter.ID.allCases)

        let plan = try #require(page.chapters.first)
        #expect(plan.number == "84")
        #expect(plan.unit == "%")
        #expect(plan.claim == "You finished 61 of the 73 tasks you planned.")
        // No trend from fewer than three points that move one way.
        #expect(plan.trend == nil)

        let byID = Dictionary(uniqueKeysWithValues: page.chapters.map { ($0.id, $0) })
        #expect(byID[.streak]?.claim == "Workdays sealed in a row.")
        #expect(byID[.delivery]?.number == "14")
        #expect(byID[.delivery]?.claim == "3 of 14 merged PRs were self-started.")
        #expect(byID[.reviews]?.number == "47")
        #expect(byID[.slipped]?.claim == "6 of 9 slips were reprioritised.")
        #expect(byID[.consistency]?.number == "19")
        #expect(byID[.consistency]?.unit == "of 19")
        // September is before the ledger, so there is nothing to compare with and nothing is invented.
        #expect(page.chapters.allSatisfy { $0.comparison == nil || !$0.comparison!.contains("September") })
    }

    @Test func everyChapterHasATableTwinAndKeepsTheCopyRules() throws {
        let home = try Home()
        defer { home.remove() }
        for range in InsightsRange.allCases {
            let data = try Self.data(home.loader(Self.thursday).load(range))
            let page = InsightsPage(data, showsStreak: true, locale: Self.gb)
            #expect(CopyRules.allows(page.title))
            for chapter in page.chapters {
                for text in [chapter.claim, chapter.comparison ?? "", chapter.note ?? ""] {
                    #expect(CopyRules.allows(text), "\(chapter.id): \(text)")
                    #expect(!text.lowercased().contains("best since"))
                }
                if let chart = chapter.chart {
                    #expect(chapter.table == chart.figures.table)
                    #expect(!(chapter.table?.rows.isEmpty ?? true), "\(chapter.id) has an empty table")
                    #expect(CopyRules.allows(chart.figures.summary), "\(chapter.id): \(chart.figures.summary)")
                    #expect(chart.figures.summary.hasSuffix("."))
                }
            }
        }
    }

    @Test func theCalendarCountsWhatTheSummaryCounts() throws {
        let home = try Home()
        defer { home.remove() }
        let data = try Self.data(home.loader(Self.thursday).load(.month))
        let calendar = ConsistencyFigures(days: data.days, locale: Self.gb)
        #expect(calendar.sealed == data.summary.sealedWorkdays)
        #expect(calendar.counted == data.summary.countedWorkdays)
        #expect(data.days.first { $0.date == LocalDate("2026-10-02") }?.state == .off(.holiday))
        #expect(data.days.first { $0.date == LocalDate("2026-10-23") }?.state == .off(.leavePlanned))
    }

    @Test func theWeekComparesWithTheSamePointLastWeek() throws {
        let home = try Home()
        defer { home.remove() }
        let data = try Self.data(home.loader(Self.thursday).load(.week))
        #expect(data.previous?.from == LocalDate("2026-10-19"))
        #expect(data.previous?.to == LocalDate("2026-10-22"))
        let page = InsightsPage(data, showsStreak: true, locale: Self.gb)
        #expect(page.label == "Week 44, 26 - 29 Oct")
        let delivery = try #require(page.chapters.first { $0.id == .delivery })
        #expect(delivery.comparison?.hasPrefix("Same point last week: ") == true)
    }

    @Test func theStreakSettingHidesTheChapter() throws {
        let home = try Home()
        defer { home.remove() }
        let data = try Self.data(home.loader(Self.thursday).load(.month))
        let page = InsightsPage(data, showsStreak: false, locale: Self.gb)
        #expect(!page.chapters.contains { $0.id == .streak })
        #expect(page.chapters.count == InsightsChapter.ID.allCases.count - 1)
    }

    // MARK: too little data

    @Test func underFifteenWorkdaysOnlyWhatIsTrueIsShown() throws {
        let home = try Home()
        defer { home.remove() }
        let data = try Self.data(home.loader(Self.friday).load(.month))
        #expect(data.workdaysSoFar < 15)
        let page = InsightsPage(data, showsStreak: true, locale: Self.gb)
        #expect(page.title == "Your patterns are still forming.")
        #expect(page.forming == InsightsPage.Forming(workdays: data.workdaysSoFar, of: 15))
        #expect(page.chapters.map(\.id) == [.streak])
        #expect(InsightsPage(data, showsStreak: false, locale: Self.gb).chapters.isEmpty)

        let none = InsightsPage(nil, showsStreak: true, locale: Self.gb)
        #expect(none.forming?.workdays == 0)
        #expect(none.chapters.isEmpty)
    }

    @Test func aMissingStoreIsAFirstRunNotAProblem() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-insights-none-\(UUID().uuidString)")
        let loader = InsightsStoreLoader(location: .found(FileRoots(home: folder)), clock: ManualClock(Date()))
        #expect(loader.stamp() == nil)
        guard case .failed(let failure) = loader.load(.week) else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.kind == .missing)
    }

    // MARK: unknown is not zero

    @Test func anEmptyLedgerPrintsDashesNotZeros() throws {
        let home = try Home(seeded: false)
        defer { home.remove() }
        var data = try Self.data(home.loader(Self.thursday).load(.month))
        // Past the forming threshold, so every chapter is built from figures that were never recorded.
        data.workdaysSoFar = 20
        let page = InsightsPage(data, showsStreak: true, locale: Self.gb)
        let byID = Dictionary(uniqueKeysWithValues: page.chapters.map { ($0.id, $0) })
        for id: InsightsChapter.ID in [.plan, .delivery, .reviews, .beyond, .slipped, .dayShape, .ai] {
            #expect(byID[id]?.number == "-", "\(id) printed \(byID[id]?.number ?? "nothing")")
        }
        #expect(byID[.plan]?.unit == nil)
        #expect(byID[.delivery]?.chart == nil)
        #expect(byID[.ai]?.chart == nil)
        #expect(byID[.ai]?.note == "Not recorded this month.")
    }

    // MARK: the cache

    final class CountingLoader: InsightsLoading, @unchecked Sendable {
        let lock = NSLock()
        var version: Int64 = 1
        var loads: [InsightsRange] = []
        let template: InsightsData

        init(template: InsightsData) { self.template = template }

        func stamp() -> InsightsStamp? {
            lock.lock()
            defer { lock.unlock() }
            return InsightsStamp(version: version, today: template.today)
        }

        func load(_ range: InsightsRange) -> InsightsLoad {
            lock.lock()
            defer { lock.unlock() }
            loads.append(range)
            var data = template
            data.range = range
            data.stamp = InsightsStamp(version: version, today: template.today)
            return .loaded(data)
        }

        func bump() {
            lock.lock()
            version += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return loads.count
        }
    }

    static func settle(_ model: InsightsModel, reads: Int) async {
        for _ in 0..<500 where model.reads < reads { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func switchingRangesIsInstantFromTheCacheAndAWriteInvalidatesIt() async throws {
        let home = try Home()
        defer { home.remove() }
        let template = try Self.data(home.loader(Self.thursday).load(.month))
        let loader = CountingLoader(template: template)
        let model = InsightsModel(loader: loader, range: .month)
        #expect(model.load == .loading)

        model.refresh()
        await Self.settle(model, reads: 1)
        #expect(loader.count == 1)

        model.select(.week)
        #expect(model.load == .loading)
        await Self.settle(model, reads: 2)
        #expect(loader.count == 2)

        // Back to the month: shown at once from the cache, and the check reads nothing.
        model.select(.month)
        guard case .loaded(let cached) = model.load else {
            Issue.record("the month was not shown from the cache")
            return
        }
        #expect(cached.range == .month)
        await Self.settle(model, reads: 3)
        #expect(loader.count == 2)

        // A write elsewhere moves the version: the next check reads again, and the week's cache is gone.
        loader.bump()
        model.refresh()
        await Self.settle(model, reads: 4)
        #expect(loader.count == 3)
        model.select(.week)
        #expect(model.load == .loading)
    }

    @Test func aRealWriteMovesTheStampAndTheNextReadSeesIt() async throws {
        let home = try Home()
        defer { home.remove() }
        let loader = home.loader(Self.thursday)
        let before = try #require(loader.stamp())
        let model = InsightsModel(loader: loader, range: .month)
        model.refresh()
        await Self.settle(model, reads: 1)
        let first = try Self.data(model.load)

        // Another connection declares Tuesday 27 October a holiday.
        let journal = try Home.journal(home.roots, ManualClock(Timestamp.parse(Self.thursday)!))
        try journal.declare(LocalDate("2026-10-27")!, kind: .holiday, label: "Example holiday", actor: .cli)

        let after = try #require(loader.stamp())
        #expect(after.version != before.version)
        model.refresh()
        await Self.settle(model, reads: 2)
        let second = try Self.data(model.load)
        #expect(second.stamp == after)
        #expect(second.summary.workdays == first.summary.workdays - 1)
    }
}
