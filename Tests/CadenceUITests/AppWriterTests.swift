import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The app's one writer, and the one story every surface tells (docs/SPEC.md sections 5.2 and 8.2).
@Suite struct AppWriterTests {
    typealias Home = DayStoreLoaderTests.Home

    final class CountingPoster: StoreChangePoster, @unchecked Sendable {
        private let lock = NSLock()
        private var posts = 0
        func postStoreChanged() { lock.withLock { posts += 1 } }
        var count: Int { lock.withLock { posts } }
    }

    @Test func aFirstWriteCreatesTheStoreAndEveryWriteIsProjectedAndPosted() async throws {
        let home = Home()
        defer { home.remove() }
        try ConfigStore.save(Config.defaults(timezone: "Asia/Kolkata"), to: home.roots.config)
        let poster = CountingPoster()
        let writer = AppWriter(location: .found(home.roots), clock: DayStoreLoaderTests.FixedClock(), poster: poster)

        let added = try await writer.perform(.planAdd(title: "Review the ACME-101 change", day: nil)).get()
        guard case .task(let task) = added else { Issue.record("expected a task"); return }
        _ = try await writer.perform(.log(LogRequest(text: "Merged the retry budget", kind: .prMerged))).get()
        _ = try await writer.perform(.resolve(task: task.id, status: .done, reason: nil)).get()
        try await writer.perform(.planCommit(day: nil, tasks: [task.id], focus: nil)).get()
        #expect(poster.count == 4)

        // What the loader reads back is what was written: projections are kept, not just the ledger.
        guard case .loaded(let state) = home.loader.load() else { Issue.record("expected a day"); return }
        #expect(state.context?.committed == true)
        #expect(state.context?.plan.map(\.status) == [.done])
        #expect(state.context?.found.map(\.title) == ["Merged the retry budget"])
    }

    @Test func aRefusedWriteIsASpecificFailureAndPostsNothing() async throws {
        let home = Home()
        defer { home.remove() }
        try ConfigStore.save(Config.defaults(timezone: "Asia/Kolkata"), to: home.roots.config)
        let poster = CountingPoster()
        let writer = AppWriter(location: .found(home.roots), clock: DayStoreLoaderTests.FixedClock(), poster: poster)
        let result = await writer.perform(.resolve(task: "missing", status: .done, reason: nil))
        guard case .failure(let failure) = result else { Issue.record("expected a failure"); return }
        #expect(failure.kind == .invalid)
        #expect(poster.count == 0)
        let unknown = AppWriter(location: .failed(StoreFailure(detail: "no home")), clock: DayStoreLoaderTests.FixedClock(), poster: poster)
        guard case .failure = await unknown.perform(.planAdd(title: "A", day: nil)) else { Issue.record("expected a failure"); return }
    }

    @Test func theStoryFollowsTheLoadAndTheAppsSignals() throws {
        let today = LocalDate("2026-09-21")!
        let now = DayStoreLoaderTests.FixedClock().now()
        #expect(DayLoad.loading.story(signals: AppSignals(), at: now, today: today) == nil)
        let missing = DayLoad.failed(StoreFailure(kind: .missing, detail: "no store"))
        #expect(missing.story(signals: AppSignals(), at: now, today: today)?.state == .firstRun)
        let broken = DayLoad.failed(StoreFailure(kind: .corrupt, detail: "bad"))
        #expect(broken.story(signals: AppSignals(), at: now, today: today)?.state == .storeProblem)

        let home = Home()
        defer { home.remove() }
        _ = try home.journal().log(LogRequest(text: "Merged the retry budget", kind: .prMerged), actor: .cli, origin: .selfReported)
        let loaded = home.loader.load()
        #expect(loaded.story(signals: AppSignals(paused: true), at: now, today: today)?.state == .paused)
        #expect(loaded.story(signals: AppSignals(setupFinished: false), at: now, today: today)?.state == .firstRun)
        let behind = AppSignals(behind: .init(source: "GitHub", lastSync: "13:40"))
        // Under ten counted days the day is still learning, which outranks a source behind.
        #expect(loaded.story(signals: behind, at: now, today: today)?.state == .learning)
    }

    @Test func failuresAreSortedIntoTheScreensOfSection4_6() {
        #expect(StoreFailure.kind(of: .storeBusy) == .busy)
        #expect(StoreFailure.kind(of: .schemaTooNew(found: 9, supported: 1)) == .newerSchema)
        #expect(StoreFailure.kind(of: .integrity("chain broken at 4")) == .corrupt)
        #expect(StoreFailure.kind(of: .io("database or disk is full")) == .diskFull)
        #expect(StoreFailure.kind(of: .io("unable to open database file")) == .denied)
        #expect(StoreFailure.kind(of: .io("file is not a database")) == .corrupt)
        #expect(StoreFailure.kind(of: .notFound("There is no cadence.db")) == .missing)
    }
}
