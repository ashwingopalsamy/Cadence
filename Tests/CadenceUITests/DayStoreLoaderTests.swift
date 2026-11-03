import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The loader against a real store in a temporary home. It reads through `Journal`, only reads, and turns
/// every problem into the error state.
@Suite struct DayStoreLoaderTests {
    struct FixedClock: Clock {
        func now() -> Date { Date(timeIntervalSince1970: 1_790_000_000) }  // 2026-09-21 19:03 in Kolkata
    }

    struct Home {
        let roots: FileRoots

        init() {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cadence-ui-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            roots = FileRoots(home: folder)
        }

        func remove() { try? FileManager.default.removeItem(at: roots.home) }

        /// A journal on the store, with the same config the loader will read from `config.json`.
        func journal() throws -> Journal {
            let config = Config.defaults(timezone: "Asia/Kolkata")
            try ConfigStore.save(config, to: roots.config)
            let clock = FixedClock()
            let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 7))
            let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
            return try Journal(store: store, config: config, clock: clock, ids: ids)
        }

        var loader: DayStoreLoader { DayStoreLoader(location: .found(roots), clock: FixedClock()) }
    }

    @Test func readsTodayFromTheJournal() throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let first = try journal.planAdd(title: "Review the ACME-101 change", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try journal.planAdd(title: "Write the notes", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try journal.planResolve(taskID: first.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        try journal.startDay(nil, at: nil, actor: .app)

        guard case .loaded(let state) = home.loader.load() else {
            Issue.record("expected the day to load")
            return
        }
        #expect(state.day == journal.today())
        #expect(state.planned == 2)
        #expect(state.resolved == 1)
        #expect(state.resolvedFraction == 0.5)
        #expect(state.tasks.map(\.title) == ["Review the ACME-101 change", "Write the notes"])
        #expect(state.startedAt == FixedClock().now())
        #expect(state.isSealed == false)
        #expect(state.onCall == false)
        #expect(state.streak != nil)
    }

    @Test func aSealedDayCarriesItsSeal() throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let task = try journal.planAdd(title: "Ship the change", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try journal.planResolve(taskID: task.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        _ = try journal.seal(nil, actor: .cli)
        guard case .loaded(let state) = home.loader.load() else {
            Issue.record("expected the day to load")
            return
        }
        #expect(state.isSealed)
        #expect(state.sealedAt != nil)
        #expect(state.streak?.current == 1)
    }

    @Test func aStoreWithNoLedgerYetIsAnEmptyDayNotAnError() throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        _ = journal  // opening the store made the file; nothing planned
        guard case .loaded(let state) = home.loader.load() else {
            Issue.record("expected the day to load")
            return
        }
        #expect(state.planned == 0)
        #expect(state.resolvedFraction == nil)
        #expect(state.startedAt == nil)
    }

    @Test func aMissingStoreIsTheErrorStateAndIsNotCreated() {
        let home = Home()
        defer { home.remove() }
        guard case .failed(let failure) = home.loader.load() else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.summary == "Cadence cannot read its store")
        #expect(failure.detail.contains("cadence.db"))
        // Reading never creates the store.
        #expect(!FileManager.default.fileExists(atPath: home.roots.database.path))
    }

    @Test func aHomeThatCannotBeReachedIsTheErrorStateNotAnotherStore() throws {
        let home = Home()
        defer { home.remove() }
        // A path below a regular file: nothing can exist there, as with a folder the sandbox denies.
        let file = home.roots.home.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)
        let unreachable = FileRoots(home: file.appendingPathComponent("dev-home", isDirectory: true))
        let load = DayStoreLoader(location: .found(unreachable), clock: FixedClock()).load()
        guard case .failed = load else {
            Issue.record("expected a failure, got \(load)")
            return
        }
    }

    @Test func aLocationThatFailedStaysFailed() {
        let failure = StoreFailure(detail: "Cadence could not find your home folder")
        #expect(DayStoreLoader(location: .failed(failure), clock: FixedClock()).load() == .failed(failure))
    }

    @Test func readingNeverWritesAGenesisOrAnythingElse() throws {
        let home = Home()
        defer { home.remove() }
        // A bare database with the schema and no events: a loader that wrote would start the ledger.
        let ids = ULIDGenerator(clock: FixedClock(), random: SeededRandomSource(seed: 1))
        let store = try SQLiteStore(path: home.roots.database.path, clock: FixedClock(), ids: ids)
        #expect(try store.eventCount() == 0)
        _ = home.loader.load()
        #expect(try store.eventCount() == 0)
    }
}
