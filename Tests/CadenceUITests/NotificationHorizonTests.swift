import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The days ahead and today's facts, read from a real store in a temporary home.
@Suite struct NotificationHorizonTests {
    static let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    static func at(_ text: String) -> Date { Timestamp.parse(text)! }

    struct Fixture {
        let roots: FileRoots
        let clock: ManualClock
        let journal: Journal
        let config: Config

        init(now: String, titles: Bool = false) throws {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cadence-ui-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            roots = FileRoots(home: folder)
            var config = Config.defaults(timezone: "Asia/Kolkata")
            config.privacy.notificationTitles = titles
            self.config = config
            try ConfigStore.save(config, to: roots.config)
            clock = ManualClock(NotificationHorizonTests.at(now))
            let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 7))
            let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
            journal = try Journal(store: store, config: config, clock: clock, ids: ids)
        }

        func remove() { try? FileManager.default.removeItem(at: roots.home) }
        var loader: NotificationHorizonLoader { NotificationHorizonLoader(location: .found(roots), clock: clock) }
    }

    @Test func declaredLeaveAndHolidaysAheadAreRead() throws {
        let f = try Fixture(now: "2026-09-21T10:00:00+05:30")
        defer { f.remove() }
        try f.journal.declare(LocalDate("2026-09-23")!, kind: .leavePlanned, label: nil, actor: .app)
        try f.journal.declare(LocalDate("2026-09-24")!, kind: .holiday, label: nil, actor: .app)
        let horizon = f.loader.load()
        #expect(horizon.declared[LocalDate("2026-09-23")!] == .leavePlanned)
        #expect(horizon.declared[LocalDate("2026-09-24")!] == .holiday)
        #expect(horizon.declared[LocalDate("2026-09-22")!] == nil)
        #expect(horizon.config == f.config)

        // Those two days carry no wrap-up reminder in the plan the app makes from it.
        let input = NotificationInput(horizon: horizon, now: f.clock.now(), state: nil)
        let days = Set(NotificationPlan.wrapReminders(input).compactMap(\.day).map(\.description))
        #expect(!days.contains("2026-09-23") && !days.contains("2026-09-24"))
        #expect(days.contains("2026-09-22") && days.contains("2026-09-25"))
        #expect(days.count == NotificationPlan.workdaysAhead)
    }

    @Test func theTitlesSettingComesFromTheConfig() throws {
        let off = try Fixture(now: "2026-09-21T10:00:00+05:30", titles: false)
        defer { off.remove() }
        let on = try Fixture(now: "2026-09-21T10:00:00+05:30", titles: true)
        defer { on.remove() }
        #expect(NotificationInput(horizon: off.loader.load(), now: off.clock.now(), state: nil).showTitles == false)
        #expect(NotificationInput(horizon: on.loader.load(), now: on.clock.now(), state: nil).showTitles)
    }

    @Test func noStoreAndNoConfigIsNothingDeclaredAndTheDefaults() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-ui-tests-\(UUID().uuidString)", isDirectory: true)
        let loader = NotificationHorizonLoader(location: .found(FileRoots(home: folder)), clock: ManualClock(Self.at("2026-09-21T10:00:00+05:30")))
        let horizon = loader.load()
        #expect(horizon.declared.isEmpty)
        #expect(horizon.config.reminders == Config.defaultReminders)
        let failed = NotificationHorizonLoader(location: .failed(StoreFailure(detail: "no home")), clock: ManualClock(Date())).load()
        #expect(failed.declared.isEmpty)
    }

    @Test func todaysFactsAreReadFromTheContext() throws {
        // Monday: two tasks, one done, one left open, then sealed. The open one is carried to Tuesday.
        let f = try Fixture(now: "2026-09-21T10:00:00+05:30")
        defer { f.remove() }
        let done = try f.journal.planAdd(title: "Write the ACME ADR", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try f.journal.planAdd(title: "Review the ACME RFC", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try f.journal.planResolve(taskID: done.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        _ = try f.journal.seal(nil, actor: .cli)

        f.clock.set(Self.at("2026-09-22T09:00:00+05:30"))
        let loader = DayStoreLoader(location: .found(f.roots), clock: f.clock)
        guard case .loaded(let state) = loader.load() else {
            Issue.record("expected the day to load")
            return
        }
        let facts = NotificationFacts(state: state, reviewsWaiting: nil)
        #expect(facts.day == LocalDate("2026-09-22")!)
        #expect(facts.carried == ["Review the ACME RFC"])
        #expect(facts.committed == false)
        #expect(facts.sealed == false)
        #expect(facts.items == 0)
        #expect(facts.reviewsWaiting == nil)

        // The prompt the app would show, counts only, and with the setting on, the title.
        var input = NotificationInput(horizon: f.loader.load(), now: f.clock.now(), state: state)
        #expect(NotificationPlan.planPrompt(input)?.title == "Plan Tuesday")
        #expect(NotificationPlan.planPrompt(input)?.body == "1 carried")
        input.showTitles = true
        #expect(NotificationPlan.planPrompt(input)?.body == "1 carried (Review the ACME RFC)")

        // Committing the plan ends the prompt.
        try f.journal.planCommit(day: nil, tasks: state.context?.carried.map(\.id) ?? [], focus: nil, actor: .app)
        guard case .loaded(let after) = loader.load() else {
            Issue.record("expected the day to load")
            return
        }
        input = NotificationInput(horizon: f.loader.load(), now: f.clock.now(), state: after)
        #expect(NotificationPlan.planPrompt(input) == nil)
        #expect(NotificationFacts(state: after).open == ["Review the ACME RFC"])
    }
}
