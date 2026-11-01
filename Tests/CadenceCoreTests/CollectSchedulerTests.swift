import Foundation
import Testing

@testable import CadenceCore

/// docs/SPEC.md section 10.2, scheduling. The clock reads Monday 2026-09-21 19:43 in Kolkata (14:13 UTC).
@Suite struct CollectSchedulerTests {
    /// Answers every command with a valid envelope for the collector named by `--name`, unless told to fail.
    final class Fake: ProcessRunner, @unchecked Sendable {
        var requests: [ProcessRequest] = []
        var failing = false

        func run(_ request: ProcessRequest) throws -> ProcessResult {
            requests.append(request)
            if failing { return CollectorRunnerTests.output("", status: 1) }
            let name = request.arguments[request.arguments.firstIndex(of: "--name")! + 1]
            return CollectorRunnerTests.output(CollectorRunnerTests.envelope(name))
        }
    }

    struct Fixture {
        let roots = FileRoots(home: TestStore.tempDirectory())
        let clock = ManualClock(TestStore.start)
        let store: SQLiteStore
        let journal: Journal
        let fake: Fake
        let runner: CollectorRunner
        let scheduler: CollectScheduler

        init(_ collectors: [Config.Collector], backfillFrom: String? = nil, failing: Bool = false) throws {
            var config = Config.defaults(timezone: "Asia/Kolkata")
            config.collectors = collectors
            config.profile.backfillFrom = backfillFrom.flatMap { LocalDate($0) }
            store = try TestStore.make(path: roots.database.path, clock: clock, projector: LedgerProjector())
            journal = try Journal(store: store, config: config, clock: clock, ids: CountingIDs())
            try Data("{}".utf8).write(to: roots.config)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: roots.config.path)
            fake = Fake()
            fake.failing = failing
            runner = CollectorRunner(
                roots: roots, journal: journal, runner: fake, selfExecutable: "/opt/cadence/bin/cadence", environment: ["HOME": "/home/sample"])
            scheduler = CollectScheduler(runner: runner, journal: journal, roots: roots, clock: clock)
            for collector in collectors {
                try runner.approve(try CollectorRunner.plan(for: collector, selfExecutable: "/opt/cadence/bin/cadence"))
            }
        }

        /// The windows of the commands run so far, as "since..until".
        var windows: [String] {
            fake.requests.map { request in
                let args = request.arguments
                return "\(args[args.firstIndex(of: "--since")! + 1])..\(args[args.firstIndex(of: "--until")! + 1])"
            }
        }

        func job(_ name: String, _ text: String, age: TimeInterval, mode: Int = 0o600) throws {
            try FileManager.default.createDirectory(at: roots.jobs, withIntermediateDirectories: true)
            let url = roots.jobs.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: mode, .modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }

        func remaining() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: roots.jobs.path)) ?? []).sorted()
        }
    }

    static func collector(_ name: String = "oncall", every: String? = nil, at: [String] = [], enabled: Bool = true) -> Config.Collector {
        Config.Collector(
            name: name, enabled: enabled, command: ["/bin/sh", "/opt/collectors/\(name).sh", "--since", "{since}", "--until", "{until}", "--name", name],
            every: every, at: at)
    }

    // MARK: - Due

    @Test func everyIsDueWhenNeverRunOrOldEnough() throws {
        let c = Self.collector(every: "15m")
        let f = try Fixture([c])
        #expect(try f.scheduler.dueCollectors().map(\.name) == ["oncall"])
        _ = try f.scheduler.runIncremental(name: "oncall")
        #expect(try f.scheduler.dueCollectors().isEmpty)
        f.clock.advance(by: 14 * 60)
        #expect(try f.scheduler.dueCollectors().isEmpty)
        f.clock.advance(by: 60)
        #expect(try f.scheduler.dueCollectors().map(\.name) == ["oncall"])
    }

    @Test func aFailedRunCountsAsARunForTheSchedule() throws {
        let f = try Fixture([Self.collector(every: "30m")], failing: true)
        let step = try #require(try f.scheduler.runIncremental(name: "oncall").first)
        #expect(step.failed)
        f.clock.advance(by: 20 * 60)
        #expect(try f.scheduler.dueCollectors().isEmpty)
        f.clock.advance(by: 10 * 60)
        #expect(try f.scheduler.dueCollectors().count == 1)
    }

    @Test func atTimesAreDueOncePerDayAfterEachTime() throws {
        let f = try Fixture([Self.collector(at: ["09:00", "18:00"])])
        // 19:43 and never run: due.
        #expect(try f.scheduler.dueCollectors().count == 1)
        _ = try f.scheduler.runIncremental(name: "oncall")
        #expect(try f.scheduler.dueCollectors().isEmpty)
        // 23:00 the same day: still nothing new.
        f.clock.advance(by: 3 * 3600 + 17 * 60)
        #expect(try f.scheduler.dueCollectors().isEmpty)
        // Next day 08:59: today's first time has not come yet.
        f.clock.advance(by: 9 * 3600 + 59 * 60)
        #expect(try f.scheduler.dueCollectors().isEmpty)
        f.clock.advance(by: 60)
        #expect(try f.scheduler.dueCollectors().count == 1)
    }

    @Test func anAtTimeNotReachedYetIsNotDue() throws {
        let f = try Fixture([Self.collector(at: ["21:00"])])
        #expect(try f.scheduler.dueCollectors().isEmpty)
        f.clock.advance(by: 77 * 60)  // 21:00
        #expect(try f.scheduler.dueCollectors().count == 1)
        _ = try f.scheduler.runIncremental(name: "oncall")
        f.clock.advance(by: 3600)
        #expect(try f.scheduler.dueCollectors().isEmpty)
    }

    @Test func aRunBeforeTheLatestAtTimeLeavesItDue() throws {
        let f = try Fixture([Self.collector(at: ["09:00", "21:00"])])
        _ = try f.scheduler.runIncremental(name: "oncall")  // 19:43, after 09:00
        f.clock.advance(by: 2 * 3600)  // 21:43
        #expect(try f.scheduler.dueCollectors().count == 1)
    }

    @Test func noScheduleAndDisabledNeverRunOnTheirOwn() throws {
        let f = try Fixture([Self.collector("manual"), Self.collector("off", every: "15m", enabled: false)])
        #expect(try f.scheduler.dueCollectors().isEmpty)
        #expect(try f.scheduler.runDue().isEmpty)
        #expect(f.fake.requests.isEmpty)
        // Asked by name, the manual one runs.
        let step = try #require(try f.scheduler.runIncremental(name: "manual").first)
        #expect(!step.failed)
    }

    @Test func runDueRunsEachDueCollectorOnceInConfigOrder() throws {
        let f = try Fixture([Self.collector("a", every: "15m"), Self.collector("b", every: "15m"), Self.collector("c")])
        let steps = try f.scheduler.runDue()
        #expect(steps.map(\.collector) == ["a", "b"])
        #expect(try f.scheduler.runDue().isEmpty)
    }

    // MARK: - Windows

    @Test func theFirstRunStartsThreeDaysBackWithoutABackfillDate() throws {
        let f = try Fixture([Self.collector(every: "15m")])
        _ = try f.scheduler.runIncremental(name: "oncall")
        #expect(f.windows == ["2026-09-18..2026-09-21"])
    }

    @Test func theFirstRunStartsAtBackfillFromWhenSet() throws {
        let f = try Fixture([Self.collector(every: "15m")], backfillFrom: "2026-09-01")
        _ = try f.scheduler.runIncremental(name: "oncall")
        // Longer than seven days, so the first catch-up runs in chunks.
        #expect(f.windows == ["2026-09-01..2026-09-07", "2026-09-08..2026-09-14", "2026-09-15..2026-09-21"])
    }

    @Test func laterRunsStartThreeDaysBeforeTheLastSuccessfulUntil() throws {
        let f = try Fixture([Self.collector(every: "15m")], backfillFrom: "2026-09-01")
        _ = try f.scheduler.runIncremental(name: "oncall")
        f.clock.advance(by: 2 * 86_400)
        _ = try f.scheduler.runIncremental(name: "oncall")
        #expect(
            f.windows == [
                "2026-09-01..2026-09-07", "2026-09-08..2026-09-14", "2026-09-15..2026-09-21", "2026-09-18..2026-09-23",
            ])
    }

    @Test func aFailedRunDoesNotMoveTheWindow() throws {
        let f = try Fixture([Self.collector(every: "15m")])
        _ = try f.scheduler.runIncremental(name: "oncall")
        f.clock.advance(by: 86_400)
        f.fake.failing = true
        _ = try f.scheduler.runIncremental(name: "oncall")
        f.clock.advance(by: 86_400)
        f.fake.failing = false
        _ = try f.scheduler.runIncremental(name: "oncall")
        #expect(f.windows == ["2026-09-18..2026-09-21", "2026-09-18..2026-09-22", "2026-09-18..2026-09-23"])
    }

    @Test func theDayComesFromTheProfileZoneNotUTC() throws {
        let f = try Fixture([Self.collector(every: "15m")])
        // 04:43 on the 22nd in Kolkata is 23:13 UTC on the 21st: the zone, not UTC, decides.
        f.clock.set(Date(timeIntervalSince1970: 1_790_000_000 + 9 * 3600))
        #expect(f.scheduler.today().description == "2026-09-22")
    }

    @Test func todayFollowsTheDayBoundaryNotCalendarMidnight() throws {
        let f = try Fixture([Self.collector(every: "15m")])
        // 00:43 on the 22nd in Kolkata is still the 21st: the day ends at 04:00 by default.
        f.clock.set(Date(timeIntervalSince1970: 1_790_000_000 + 5 * 3600))
        #expect(f.scheduler.today().description == "2026-09-21")
        _ = try f.scheduler.runIncremental(name: "oncall")
        #expect(f.windows == ["2026-09-18..2026-09-21"])
        // After 04:00 it is the 22nd.
        f.clock.advance(by: 3 * 3600 + 17 * 60)
        #expect(f.scheduler.today().description == "2026-09-22")
    }

    @Test func aLongStreakOfFailuresDoesNotLoseTheLastGoodRun() throws {
        let f = try Fixture([Self.collector(every: "15m")], backfillFrom: "2026-09-01")
        _ = try f.scheduler.runIncremental(name: "oncall")
        f.fake.requests.removeAll()
        f.fake.failing = true
        for _ in 0..<501 {
            f.clock.advance(by: 1)
            _ = try f.scheduler.runIncremental(name: "oncall")
        }
        #expect(f.fake.requests.count == 501)
        f.fake.requests.removeAll()
        f.fake.failing = false
        f.clock.advance(by: 1)
        _ = try f.scheduler.runIncremental(name: "oncall")
        // The last good run read through the 21st, so the window starts on the 18th, not at backfillFrom.
        #expect(f.windows == ["2026-09-18..2026-09-21"])
        let history = try f.scheduler.history(name: "oncall")
        #expect(history.lastOkUntil?.description == "2026-09-21" && history.lastStatus == "ok")
    }

    @Test func theLastGoodDayIsTheFurthestOneNotTheLatestRun() throws {
        let f = try Fixture([Self.collector(every: "15m")])
        _ = try f.scheduler.runIncremental(name: "oncall")  // reads through the 21st
        f.clock.advance(by: 60)
        // A run over an older window finishes last but does not move the window back.
        _ = try f.scheduler.runWindow(name: "oncall", since: LocalDate("2026-09-01")!, until: LocalDate("2026-09-02")!)
        #expect(try f.scheduler.history(name: "oncall").lastOkUntil?.description == "2026-09-21")
        f.fake.requests.removeAll()
        _ = try f.scheduler.runIncremental(name: "oncall")
        #expect(f.windows == ["2026-09-18..2026-09-21"])
    }

    @Test func aLongGapIsReadInSevenDayChunks() throws {
        let f = try Fixture([Self.collector(every: "15m")])
        _ = try f.scheduler.runIncremental(name: "oncall")  // through 2026-09-21
        f.fake.requests.removeAll()
        f.clock.advance(by: 21 * 86_400)  // the laptop was off for three weeks: today is 2026-10-12
        let steps = try f.scheduler.runIncremental(name: "oncall")
        #expect(
            f.windows == ["2026-09-18..2026-09-24", "2026-09-25..2026-10-01", "2026-10-02..2026-10-08", "2026-10-09..2026-10-12"])
        #expect(steps.count == 4 && steps.allSatisfy { !$0.failed })
        // The run that follows picks up three days before the last chunk's end.
        f.fake.requests.removeAll()
        f.clock.advance(by: 3600)
        _ = try f.scheduler.runIncremental(name: "oncall")
        #expect(f.windows == ["2026-10-09..2026-10-12"])
    }

    @Test func aFailedChunkStopsTheCatchUpAndTheNextRunResumesThere() throws {
        let f = try Fixture([Self.collector(every: "15m")])
        _ = try f.scheduler.runIncremental(name: "oncall")
        f.fake.requests.removeAll()
        f.clock.advance(by: 21 * 86_400)
        f.fake.failing = true
        let steps = try f.scheduler.runIncremental(name: "oncall")
        #expect(steps.count == 1 && steps[0].failed)
        #expect(f.windows == ["2026-09-18..2026-09-24"])
        f.fake.requests.removeAll()
        f.fake.failing = false
        _ = try f.scheduler.runIncremental(name: "oncall")
        #expect(f.windows.first == "2026-09-18..2026-09-24" && f.windows.count == 4)
    }

    // MARK: - An exact window

    @Test func anExactWindowRunsAsGivenAndInChunksWhenLong() throws {
        let f = try Fixture([Self.collector()])
        let one = try f.scheduler.runWindow(name: "oncall", since: LocalDate("2026-09-10")!, until: LocalDate("2026-09-12")!)
        #expect(one.count == 1 && f.windows == ["2026-09-10..2026-09-12"])
        f.fake.requests.removeAll()
        let long = try f.scheduler.runWindow(name: "oncall", since: LocalDate("2026-08-30")!, until: LocalDate("2026-09-21")!)
        #expect(long.count == 4)
        #expect(f.windows == ["2026-08-30..2026-09-05", "2026-09-06..2026-09-12", "2026-09-13..2026-09-19", "2026-09-20..2026-09-21"])
    }

    @Test func anExactWindowStopsAtTheFirstFailedChunk() throws {
        let f = try Fixture([Self.collector()], failing: true)
        let steps = try f.scheduler.runWindow(name: "oncall", since: LocalDate("2026-08-30")!, until: LocalDate("2026-09-21")!)
        #expect(steps.count == 1 && steps[0].failed && f.fake.requests.count == 1)
    }

    @Test func anExactWindowIsChecked() throws {
        let f = try Fixture([Self.collector()])
        func refused(_ since: String, _ until: String) -> String? {
            do {
                _ = try f.scheduler.runWindow(name: "oncall", since: LocalDate(since)!, until: LocalDate(until)!)
                return nil
            } catch { return error.message }
        }
        #expect(refused("2026-09-12", "2026-09-10") == "--since 2026-09-12 is after --until 2026-09-10")
        #expect(refused("2026-09-12", "2026-09-22") == "--until 2026-09-22 is in the future; today is 2026-09-21")
        #expect(refused("1999-12-31", "2026-09-21") == "--since 1999-12-31 is before 2000-01-01")
        #expect(f.fake.requests.isEmpty)
        // Today itself is fine.
        #expect(refused("2026-09-21", "2026-09-21") == nil)
    }

    @Test func anUntilOnTheCalendarDayBeforeTheDayBoundaryIsNotInTheFuture() throws {
        let f = try Fixture([Self.collector()])
        // 02:00 on the 22nd in Kolkata: the workday is still the 21st, but the calendar says the 22nd.
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        f.clock.set(Timestamp.instant(clockTime: "02:00", on: LocalDate("2026-09-22")!, in: zone)!)
        #expect(f.scheduler.today() == LocalDate("2026-09-21")!)
        func refused(_ since: String, _ until: String) -> String? {
            do {
                _ = try f.scheduler.runWindow(name: "oncall", since: LocalDate(since)!, until: LocalDate(until)!)
                return nil
            } catch { return error.message }
        }
        // Up to the calendar today is allowed, a day later is not.
        #expect(refused("2026-09-20", "2026-09-22") == nil)
        #expect(f.windows == ["2026-09-20..2026-09-22"])
        f.fake.requests.removeAll()
        #expect(refused("2026-09-22", "2026-09-22") == nil)
        #expect(refused("2026-09-20", "2026-09-23") == "--until 2026-09-23 is in the future; today is 2026-09-22")
        #expect(f.fake.requests.count == 1)  // only the second window ran
        // Past the boundary the two days are the same again, and the message is as before.
        f.clock.set(Timestamp.instant(clockTime: "05:00", on: LocalDate("2026-09-22")!, in: zone)!)
        #expect(f.scheduler.today() == LocalDate("2026-09-22")!)
        #expect(refused("2026-09-20", "2026-09-23") == "--until 2026-09-23 is in the future; today is 2026-09-22")
        #expect(refused("2026-09-20", "2026-09-22") == nil)
    }

    // MARK: - Backfill

    @Test func chunksAreSevenDaysOldestFirstAndEndToday() {
        let chunks = CollectScheduler.chunks(from: LocalDate("2026-09-01")!, through: LocalDate("2026-09-21")!)
        #expect(chunks.map { "\($0.since)..\($0.until)" } == ["2026-09-01..2026-09-07", "2026-09-08..2026-09-14", "2026-09-15..2026-09-21"])
        let odd = CollectScheduler.chunks(from: LocalDate("2026-09-15")!, through: LocalDate("2026-09-21")!)
        #expect(odd.count == 1)
        let ragged = CollectScheduler.chunks(from: LocalDate("2026-09-13")!, through: LocalDate("2026-09-21")!)
        #expect(ragged.map { "\($0.since)..\($0.until)" } == ["2026-09-13..2026-09-19", "2026-09-20..2026-09-21"])
        #expect(CollectScheduler.chunks(from: LocalDate("2026-09-22")!, through: LocalDate("2026-09-21")!).isEmpty)
    }

    @Test func backfillRunsEachChunkAsItsOwnRun() throws {
        let f = try Fixture([Self.collector()], backfillFrom: "2026-09-01")
        let steps = try f.scheduler.backfill(name: "oncall", from: nil)
        #expect(steps.count == 3 && steps.allSatisfy { !$0.failed })
        #expect(f.windows == ["2026-09-01..2026-09-07", "2026-09-08..2026-09-14", "2026-09-15..2026-09-21"])
        #expect(try f.store.events(after: 0, limit: 1000).filter { $0.type == "ingest.run" }.count == 3)
    }

    @Test func backfillFromARequestedDateWinsOverTheProfile() throws {
        let f = try Fixture([Self.collector()], backfillFrom: "2026-09-01")
        _ = try f.scheduler.backfill(name: "oncall", from: LocalDate("2026-09-15"))
        #expect(f.windows == ["2026-09-15..2026-09-21"])
    }

    @Test func aBackfillStartMustBeBetween2000AndToday() throws {
        #expect(
            CollectJob.parse(Array(#"{"job":"backfill","name":"a","from":"2000-01-01"}"#.utf8))
                == .backfill(name: "a", from: LocalDate("2000-01-01")))
        #expect(CollectJob.parse(Array(#"{"job":"backfill","name":"a","from":"1999-12-31"}"#.utf8)) == nil)
        let f = try Fixture([Self.collector("a")])
        try f.job("late.json", #"{"job":"backfill","name":"a","from":"2026-09-22"}"#, age: 3)
        try f.job("early.json", #"{"job":"backfill","name":"a","from":"1999-12-31"}"#, age: 2)
        try f.job("today.json", #"{"job":"backfill","name":"a","from":"2026-09-21"}"#, age: 1)
        let outcomes = try f.scheduler.processJobs()
        #expect(outcomes.map(\.file) == ["late.json", "early.json", "today.json"])
        #expect(outcomes.map { $0.job == nil } == [true, true, false])
        #expect(outcomes.allSatisfy(\.removed) && f.remaining().isEmpty)
        #expect(f.windows == ["2026-09-21..2026-09-21"])
        do {
            _ = try f.scheduler.backfill(name: "a", from: LocalDate("2026-09-22"))
            Issue.record("a backfill from tomorrow should be refused")
        } catch {
            #expect(error.message == "backfill: 2026-09-22 is in the future; today is 2026-09-21")
        }
    }

    @Test func backfillStopsAtTheFirstFailedChunk() throws {
        let f = try Fixture([Self.collector()], backfillFrom: "2026-09-01", failing: true)
        let steps = try f.scheduler.backfill(name: "oncall", from: nil)
        #expect(steps.count == 1 && steps[0].failed)
        #expect(f.fake.requests.count == 1)
    }

    @Test func backfillStopsWhenTheCommandIsNotApproved() throws {
        let f = try Fixture([Self.collector()], backfillFrom: "2026-09-01")
        // A runner that never approved this plan.
        let fresh = FileRoots(home: TestStore.tempDirectory())
        let runner = CollectorRunner(roots: fresh, journal: f.journal, runner: f.fake, selfExecutable: "/x", environment: [:])
        let scheduler = CollectScheduler(runner: runner, journal: f.journal, roots: fresh, clock: f.clock)
        let steps = try scheduler.backfill(name: "oncall", from: nil)
        #expect(steps.count == 1 && steps[0].failed)
        #expect(f.fake.requests.isEmpty)
    }

    // MARK: - Jobs

    @Test func jobsRunOldestFirstAndAreDeletedAfterwards() throws {
        let f = try Fixture([Self.collector("a"), Self.collector("b")], backfillFrom: "2026-09-15")
        try f.job("2-new.json", #"{"job":"run","name":"b"}"#, age: 10)
        try f.job("1-old.json", #"{"job":"backfill","name":"a","from":"2026-09-10"}"#, age: 100)
        try f.job("notes.txt", "keep me", age: 50)
        let outcomes = try f.scheduler.processJobs()
        #expect(outcomes.map(\.file) == ["1-old.json", "2-new.json"])
        #expect(outcomes.allSatisfy { $0.removed })
        #expect(f.windows == ["2026-09-10..2026-09-16", "2026-09-17..2026-09-21", "2026-09-15..2026-09-21"])
        #expect(f.remaining() == ["notes.txt"])
    }

    @Test func aRefusedJobIsStillHandledAndRemoved() throws {
        let f = try Fixture([Self.collector("a", enabled: false)])
        try f.job("x.json", #"{"job":"run","name":"a"}"#, age: 1)
        try f.job("y.json", #"{"job":"run","name":"nobody"}"#, age: 0)
        let outcomes = try f.scheduler.processJobs()
        #expect(outcomes[0].steps.first?.result == .refused(.disabled))
        #expect(outcomes[1].steps.first?.result == .refused(.unknown("nobody")))
        #expect(outcomes.allSatisfy { $0.removed } && f.remaining().isEmpty)
        #expect(f.fake.requests.isEmpty)
    }

    @Test func invalidJobsAreRejectedWithoutRunningAnything() throws {
        let f = try Fixture([Self.collector("a")])
        let bad = [
            "garbage", #"{"job":"shell","name":"a"}"#, #"{"job":"run"}"#, #"{"job":"run","name":"a","extra":1}"#,
            #"{"job":"run","name":"../etc"}"#, #"{"job":"backfill","name":"a","from":"yesterday"}"#,
            #"{"job":"backfill","name":"a","from":5}"#, #"[1]"#,
        ]
        for (index, text) in bad.enumerated() { try f.job("bad\(index).json", text, age: Double(100 - index)) }
        try f.job("open.json", #"{"job":"run","name":"a"}"#, age: 1, mode: 0o644)
        let outcomes = try f.scheduler.processJobs()
        #expect(outcomes.count == bad.count + 1)
        #expect(outcomes.allSatisfy { $0.job == nil && $0.removed })
        #expect(f.fake.requests.isEmpty && f.remaining().isEmpty)
    }

    @Test func aJobThatMeetsABusyLockIsKept() throws {
        let f = try Fixture([Self.collector("a")])
        try f.job("x.json", #"{"job":"run","name":"a"}"#, age: 1)
        let lock = try #require(try RunLock(f.roots.state.appendingPathComponent("locks/a.lock")))
        defer { lock.release() }
        let outcomes = try f.scheduler.processJobs()
        #expect(outcomes.count == 1 && !outcomes[0].removed)
        #expect(f.remaining() == ["x.json"])
    }

    @Test func noJobsFolderIsFine() throws {
        let f = try Fixture([Self.collector("a")])
        #expect(try f.scheduler.processJobs().isEmpty)
    }

    // MARK: - launchd template

    @Test func theLaunchAgentTemplateIsAPlistWithTheSpecKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("App/Agent.plist.in")
        let data = try Data(contentsOf: url)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "@BUNDLE_ID@.agent")
        #expect(plist["BundleProgram"] as? String == "Contents/Helpers/cadence")
        #expect((plist["ProgramArguments"] as? [String])?.suffix(3) == ["collect", "run", "--due"])
        #expect(plist["StartInterval"] as? Int == 900)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["WatchPaths"] as? [String] == ["@JOBS_PATH@"])
    }
}
