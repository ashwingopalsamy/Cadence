import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The model reads off the main thread, publishes on the main actor and collapses a burst of requests.
@MainActor @Suite struct DayModelTests {
    /// A loader the test controls: it counts calls, notes the thread, can be held, and hands out numbered days.
    final class ScriptedLoader: DayLoading, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var onMain = false
        private var results: [DayLoad] = []
        /// While set, `load` waits for `release()`.
        private var gate: DispatchSemaphore?

        init(hold: Bool = false) { gate = hold ? DispatchSemaphore(value: 0) : nil }

        var callCount: Int { lock.withLock { calls } }
        var everRanOnMainThread: Bool { lock.withLock { onMain } }

        func queue(_ result: DayLoad) { lock.withLock { results.append(result) } }
        func release() { gate?.signal() }

        func load() -> DayLoad {
            let wait: DispatchSemaphore? = lock.withLock {
                calls += 1
                if Thread.isMainThread { onMain = true }
                return calls == 1 ? gate : nil
            }
            wait?.wait()
            return lock.withLock { results.isEmpty ? .failed(StoreFailure(detail: "nothing scripted")) : results.removeFirst() }
        }
    }

    static func day(planned: Int) -> DayLoad {
        let tasks = (0..<planned).map { i in
            PlanTask(
                id: "t\(i)", day: "2026-09-21", position: Int64(i), title: "Task \(i)", origin: .selfReported,
                plannedAt: "2026-09-21T09:00:00+05:30")
        }
        let view = DayView(day: Day(date: "2026-09-21", tz: "Asia/Kolkata"), tasks: tasks, entries: [], presence: [])
        return .loaded(DayState(day: LocalDate("2026-09-21")!, view: view, streak: nil))
    }

    /// Waits on the main actor, which stays free to publish, until `condition` holds.
    func until(timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func startsWithNothingKnown() {
        let model = DayModel(loader: ScriptedLoader())
        #expect(model.load == .loading)
        #expect(model.state == nil)
        #expect(model.failure == nil)
    }

    @Test func readsOffTheMainThreadAndPublishesTheDay() async {
        let loader = ScriptedLoader()
        loader.queue(Self.day(planned: 3))
        let model = DayModel(loader: loader)
        model.reload()
        #expect(await until { model.state != nil })
        #expect(model.state?.planned == 3)
        #expect(loader.callCount == 1)
        #expect(loader.everRanOnMainThread == false)
    }

    @Test func reloadReturnsAtOnceWhileTheReadIsStillRunning() async {
        let loader = ScriptedLoader(hold: true)
        loader.queue(Self.day(planned: 1))
        let model = DayModel(loader: loader)
        model.reload()
        // The read is stuck on the disk; the main actor is not.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.load == .loading)
        loader.release()
        #expect(await until { model.state != nil })
    }

    @Test func aBurstOfReloadsIsAtMostTwoReadsAndTheLastIsTheNewest() async {
        let loader = ScriptedLoader(hold: true)
        loader.queue(Self.day(planned: 1))  // read while the burst arrives
        loader.queue(Self.day(planned: 2))  // read after it
        loader.queue(Self.day(planned: 99))  // would only be read by a third pass
        let model = DayModel(loader: loader)
        model.reload()
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<100 { model.reload() }
        loader.release()
        #expect(await until { model.state?.planned == 2 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(loader.callCount == 2)
        #expect(model.state?.planned == 2)
    }

    @Test func aReloadAfterTheReadsFinishedReadsAgain() async {
        let loader = ScriptedLoader()
        loader.queue(Self.day(planned: 1))
        loader.queue(Self.day(planned: 4))
        let model = DayModel(loader: loader)
        model.reload()
        #expect(await until { model.state?.planned == 1 })
        model.reload()
        #expect(await until { model.state?.planned == 4 })
        #expect(loader.callCount == 2)
    }

    @Test func aFailedReadReplacesTheDayAndARecoveryRestoresIt() async {
        let loader = ScriptedLoader()
        loader.queue(Self.day(planned: 3))
        loader.queue(.failed(StoreFailure(detail: "unable to open database file")))
        loader.queue(Self.day(planned: 3))
        let model = DayModel(loader: loader)
        model.reload()
        #expect(await until { model.state != nil })
        model.reload()
        #expect(await until { model.failure != nil })
        // Old numbers do not stay on screen as current: with no store read, nothing is known.
        #expect(model.state == nil)
        #expect(model.failure?.detail == "unable to open database file")
        model.reload()
        #expect(await until { model.state != nil })
        #expect(model.failure == nil)
    }
}
