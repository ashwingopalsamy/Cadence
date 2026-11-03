import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The app's background jobs (docs/SPEC.md sections 5.2, 8.1 and 10.2): spool drain, daily backup, agent registration
/// and source health, each one supervised and reporting when it last worked and what it said.
@Suite struct HousekeepingTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!

    /// 2026-10-29 at the given local time in Kolkata.
    static func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Timestamp.parse(String(format: "2026-10-29T%02d:%02d:%02d+05:30", hour, minute, second))!
    }

    // MARK: Fakes

    final class FakeWork: HousekeepingWork, @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [HousekeepingJob: Int] = [:]
        var drain: @Sendable () async -> Result<DrainReport, StoreFailure> = { .success(DrainReport()) }
        var backup: @Sendable () async -> Result<BackupOutcome, StoreFailure> = {
            .success(BackupOutcome(created: false, day: "2026-10-29", events: nil, pruned: 0))
        }
        var sources: @Sendable () async -> Result<[CollectorSource], StoreFailure> = { .success([]) }

        func calls(_ job: HousekeepingJob) -> Int { lock.withLock { counts[job] ?? 0 } }
        private func note(_ job: HousekeepingJob) { lock.withLock { counts[job, default: 0] += 1 } }

        func drainSpool() async -> Result<DrainReport, StoreFailure> {
            note(.spoolDrain)
            return await drain()
        }
        func runBackup() async -> Result<BackupOutcome, StoreFailure> {
            note(.backup)
            return await backup()
        }
        func collectorSources() async -> Result<[CollectorSource], StoreFailure> {
            note(.collectors)
            return await sources()
        }
    }

    final class FakeAgent: AgentStatusReading, @unchecked Sendable {
        private let lock = NSLock()
        private var value: AgentRegistration
        private var reads = 0
        init(_ value: AgentRegistration) { self.value = value }
        func set(_ next: AgentRegistration) { lock.withLock { value = next } }
        var readCount: Int { lock.withLock { reads } }
        func registration() -> AgentRegistration { lock.withLock { reads += 1; return value } }
    }

    final class FakeSignal: StoreChangeSignal, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable () -> Void)?
        var started: Bool { lock.withLock { handler != nil } }
        func start(_ handler: @escaping @Sendable () -> Void) { lock.withLock { self.handler = handler } }
        func stop() { lock.withLock { handler = nil } }
        func fire() { lock.withLock { handler }?() }
    }

    /// Time as the jobs see it: a sleep waits until the test lets time pass.
    final class ManualSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [(seconds: TimeInterval, resume: CheckedContinuation<Void, Never>)] = []

        var requested: [TimeInterval] { lock.withLock { waiting.map(\.seconds).sorted() } }

        func sleep(_ seconds: TimeInterval) async {
            await withCheckedContinuation { resume in lock.withLock { waiting.append((seconds, resume)) } }
        }

        func advance() {
            let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                defer { waiting = [] }
                return waiting.map(\.resume)
            }
            for resume in ready { resume.resume() }
        }
    }

    final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [HousekeepingStatus] = []
        func add(_ status: HousekeepingStatus) { lock.withLock { seen.append(status) } }
        var all: [HousekeepingStatus] { lock.withLock { seen } }
    }

    func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    func housekeeping(
        _ work: FakeWork = FakeWork(), agent: FakeAgent = FakeAgent(.enabled), signal: FakeSignal = FakeSignal(),
        clock: ManualClock = ManualClock(at(9, 0)), sleeper: ManualSleeper = ManualSleeper(), changes: Changes = Changes()
    ) -> Housekeeping {
        Housekeeping(
            work: work, agent: agent, signal: signal, clock: clock,
            sleep: { seconds in await sleeper.sleep(seconds) }, onChange: { changes.add($0) })
    }

    // MARK: Health

    @Test func eachRunRecordsLastSuccessLastFailureAndWhatItSaid() async {
        let work = FakeWork()
        let clock = ManualClock(Self.at(9, 0))
        let hk = housekeeping(work, clock: clock)
        #expect(hk.status.jobs[.spoolDrain] == JobHealth())

        let report = {
            var report = DrainReport()
            report.eventsWritten = 2
            return report
        }()
        work.drain = { .success(report) }
        await hk.run(.spoolDrain)
        let ok = hk.status.jobs[.spoolDrain]
        #expect(ok?.lastSuccess == Self.at(9, 0))
        #expect(ok?.lastFailure == nil)
        #expect(ok?.isFailing == false)
        #expect(ok?.message == report.summary)

        clock.set(Self.at(9, 5))
        work.drain = { .failure(StoreFailure(kind: .busy, detail: "the store is busy")) }
        await hk.run(.spoolDrain)
        let failed = hk.status.jobs[.spoolDrain]
        #expect(failed?.lastSuccess == Self.at(9, 0))
        #expect(failed?.lastFailure == Self.at(9, 5))
        #expect(failed?.isFailing == true)
        #expect(failed?.message == "the store is busy")

        clock.set(Self.at(9, 10))
        work.drain = { .success(DrainReport()) }
        await hk.run(.spoolDrain)
        #expect(hk.status.jobs[.spoolDrain]?.isFailing == false)
        #expect(hk.status.jobs[.spoolDrain]?.lastSuccess == Self.at(9, 10))
        #expect(hk.status.jobs[.spoolDrain]?.lastFailure == Self.at(9, 5))
    }

    @Test func theBackupSaysWhetherItMadeOneOrTodaysAlreadyExisted() async {
        let work = FakeWork()
        let hk = housekeeping(work)
        work.backup = { .success(BackupOutcome(created: true, day: "2026-10-29", events: 120, pruned: 2)) }
        await hk.run(.backup)
        #expect(hk.status.jobs[.backup]?.message == "Backed up 120 events for 2026-10-29, removed 2 old backups")
        work.backup = { .success(BackupOutcome(created: false, day: "2026-10-29", events: nil, pruned: 0)) }
        await hk.run(.backup)
        #expect(hk.status.jobs[.backup]?.message == "Today's backup, 2026-10-29, already exists")
        work.backup = { .failure(StoreFailure(kind: .corrupt, detail: "backup for 2026-10-29 failed verification")) }
        await hk.run(.backup)
        #expect(hk.status.jobs[.backup]?.isFailing == true)
    }

    @Test func theAgentStatusIsReadAndAnythingButEnabledIsAFailureWithAWayOut() async {
        let agent = FakeAgent(.enabled)
        let hk = housekeeping(agent: agent)
        await hk.run(.agent)
        #expect(hk.status.agentRegistration == .enabled)
        #expect(hk.status.jobs[.agent]?.isFailing == false)

        agent.set(.requiresApproval)
        await hk.run(.agent)
        #expect(hk.status.agentRegistration == .requiresApproval)
        #expect(hk.status.jobs[.agent]?.isFailing == true)
        #expect(hk.status.jobs[.agent]?.message == "Allow Cadence in System Settings, General, Login Items, so collectors can run")

        agent.set(.notRegistered)
        await hk.run(.agent)
        #expect(hk.status.jobs[.agent]?.message == "The collector agent is not registered")
        agent.set(.notFound)
        await hk.run(.agent)
        #expect(hk.status.jobs[.agent]?.message == "The collector agent is missing from the app")
    }

    // MARK: Sources

    func facts(
        _ collector: Config.Collector, failures: Int = 0, lastGood: Date? = nil, produced: Bool = false, now: Date = at(15, 0)
    ) -> CollectorSource {
        CollectorSource.make(
            collector: collector, failuresInARow: failures, lastError: failures > 0 ? "exit status 1" : nil,
            lastGoodRun: lastGood, producedItems: produced, now: now, zone: Self.zone)
    }

    let github = Config.Collector(name: "github", builtin: "github", gh: "/opt/homebrew/bin/gh", every: "30m")
    let transcripts = Config.Collector(name: "claude-code", builtin: "claude-code-transcripts", every: "60m")

    @Test func aSourceIsFailingAfterThreeFailuresInARowAndNotBefore() {
        #expect(facts(github, failures: 2, lastGood: Self.at(14, 50)).isFailing == false)
        let failing = facts(github, failures: 3, lastGood: Self.at(13, 40))
        #expect(failing.isFailing)
        #expect(failing.isBehind)
        #expect(failing.title == "GitHub")
        #expect(failing.lastSync == "13:40")
        #expect(failing.lastError == "exit status 1")
    }

    @Test func aSourceThreeRunsOverdueIsBehindEvenWithoutAFailure() {
        // Every 30 minutes: three runs are 90 minutes.
        #expect(facts(github, lastGood: Self.at(13, 29)).isOverdue)
        #expect(facts(github, lastGood: Self.at(13, 29)).isBehind)
        #expect(!facts(github, lastGood: Self.at(13, 31)).isOverdue)
        #expect(!facts(github, lastGood: Self.at(13, 31)).isBehind)
    }

    @Test func aSourceThatNeverRanIsNotBehindAndOneThatNeverWorkedHasNoSyncTime() {
        let new = facts(github)
        #expect(!new.isBehind)
        #expect(new.lastSync == "-")
        let neverWorked = facts(github, failures: 3)
        #expect(neverWorked.isBehind)
        #expect(neverWorked.lastSync == "-")
    }

    @Test func aSourceWithoutAScheduleIsNeverOverdue() {
        let manual = Config.Collector(name: "manual", command: ["/usr/bin/true"])
        #expect(!facts(manual, lastGood: Self.at(9, 0).addingTimeInterval(-30 * 86_400), produced: true).isOverdue)
    }

    @Test func aDailySourceIsOverdueAfterThreeDays() {
        let daily = Config.Collector(name: "usage", command: ["/usr/bin/true"], at: ["17:10"])
        let now = Self.at(15, 0)
        #expect(!facts(daily, lastGood: now.addingTimeInterval(-71 * 3600), produced: true, now: now).isOverdue)
        #expect(facts(daily, lastGood: now.addingTimeInterval(-73 * 3600), produced: true, now: now).isOverdue)
    }

    @Test func onlyASourceThatFeedsTheCountCanMakeTheDayBehind() {
        // AI is a tool, not an outcome: the transcripts reader never feeds the count.
        let ai = facts(transcripts, failures: 5, lastGood: Self.at(8, 0))
        #expect(ai.isFailing)
        #expect(!ai.feedsCount)
        #expect(!ai.isBehind)
        #expect(ai.title == "Claude Code")
        // A command collector feeds it once it has produced counted items.
        let command = Config.Collector(name: "tickets", command: ["/usr/bin/true"], every: "30m")
        #expect(!facts(command, failures: 3, lastGood: Self.at(8, 0)).isBehind)
        let producing = facts(command, failures: 3, lastGood: Self.at(8, 0), produced: true)
        #expect(producing.feedsCount && producing.isBehind)
        #expect(producing.title == "tickets")
    }

    @Test func behindNamesTheSourceThatHasBeenSilentLongest() {
        var status = HousekeepingStatus()
        #expect(status.behind == nil)
        let other = Config.Collector(name: "tickets", command: ["/usr/bin/true"], every: "30m")
        status.sources = [
            facts(github, failures: 3, lastGood: Self.at(13, 40)),
            facts(other, failures: 3, lastGood: Self.at(11, 5), produced: true),
            facts(transcripts, failures: 3, lastGood: Self.at(2, 0)),
        ]
        #expect(status.behind == .init(source: "tickets", lastSync: "11:05"))
        status.sources = [facts(github, lastGood: Self.at(14, 50))]
        #expect(status.behind == nil)
    }

    @Test func sourceHealthJobFillsTheStatusAndTheBehindSignal() async {
        let work = FakeWork()
        let behind = facts(github, failures: 3, lastGood: Self.at(13, 40))
        work.sources = { .success([behind]) }
        let hk = housekeeping(work)
        await hk.run(.collectors)
        #expect(hk.status.sources == [behind])
        #expect(hk.status.behind == .init(source: "GitHub", lastSync: "13:40"))
        #expect(hk.status.jobs[.collectors]?.message == "1 source checked, GitHub is behind")

        work.sources = { .success([facts(github, lastGood: Self.at(14, 55)), facts(transcripts, lastGood: Self.at(14, 0))]) }
        await hk.run(.collectors)
        #expect(hk.status.behind == nil)
        #expect(hk.status.jobs[.collectors]?.message == "2 sources checked")

        work.sources = { .failure(StoreFailure(kind: .busy, detail: "the store is busy")) }
        await hk.run(.collectors)
        // The last reading stands while a new one cannot be made, and the failure is reported.
        #expect(hk.status.jobs[.collectors]?.isFailing == true)
        #expect(hk.status.sources.count == 2)
    }

    // MARK: Supervision

    @Test func startRunsEveryJobAtOnceThenOnItsOwnSchedule() async {
        let work = FakeWork()
        let agent = FakeAgent(.enabled)
        let signal = FakeSignal()
        let sleeper = ManualSleeper()
        let hk = housekeeping(work, agent: agent, signal: signal, sleeper: sleeper)
        hk.start()
        defer { hk.stop() }

        #expect(await eventually { work.calls(.spoolDrain) == 1 && work.calls(.backup) == 1 && work.calls(.collectors) == 1 && agent.readCount == 1 })
        #expect(await eventually { sleeper.requested.count == 4 })
        #expect(sleeper.requested == [300, 300, 900, 3600])
        #expect(signal.started)

        sleeper.advance()
        #expect(await eventually { work.calls(.spoolDrain) == 2 && work.calls(.backup) == 2 && work.calls(.collectors) == 2 && agent.readCount == 2 })
    }

    @Test func aFailingJobIsReportedAndTheOthersCarryOn() async {
        let work = FakeWork()
        work.drain = { .failure(StoreFailure(kind: .other, detail: "cannot read the spool")) }
        let sleeper = ManualSleeper()
        let hk = housekeeping(work, sleeper: sleeper)
        hk.start()
        defer { hk.stop() }

        #expect(await eventually { sleeper.requested.count == 4 })
        #expect(hk.status.jobs[.spoolDrain]?.isFailing == true)
        #expect(hk.status.jobs[.backup]?.isFailing == false)
        #expect(hk.status.jobs[.agent]?.isFailing == false)
        #expect(hk.status.jobs[.collectors]?.isFailing == false)
        // The failing job is tried again on schedule.
        sleeper.advance()
        #expect(await eventually { work.calls(.spoolDrain) == 2 })
    }

    @Test func aStoreChangeRunsTheSpoolDrainAndSourceCheckButNotTooOften() async {
        let work = FakeWork()
        let signal = FakeSignal()
        let clock = ManualClock(Self.at(9, 0))
        let hk = housekeeping(work, signal: signal, clock: clock)
        hk.start()
        defer { hk.stop() }
        #expect(await eventually { work.calls(.spoolDrain) == 1 && work.calls(.collectors) == 1 })

        // Our own writes and the CLI's both signal; a burst inside the gap is one run, and the schedule catches up.
        clock.advance(by: 20)
        signal.fire()
        #expect(await eventually { work.calls(.spoolDrain) == 2 && work.calls(.collectors) == 2 })
        clock.advance(by: 2)
        signal.fire()
        signal.fire()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(work.calls(.spoolDrain) == 2)
        #expect(work.calls(.collectors) == 2)
        // The backup and the agent have nothing to do with a change.
        #expect(work.calls(.backup) == 1)
    }

    @Test func aRunAskedForWhileOneIsRunningRunsOnceMoreAfterIt() async {
        let work = FakeWork()
        let gate = AsyncGate()
        work.drain = {
            await gate.wait()
            return .success(DrainReport())
        }
        let hk = housekeeping(work)

        let first = Task { await hk.run(.spoolDrain) }
        #expect(await eventually { work.calls(.spoolDrain) == 1 })
        // Two more asks while it runs collapse into one more run: spool files are drained in order, never twice at once.
        await hk.run(.spoolDrain)
        await hk.run(.spoolDrain)
        #expect(work.calls(.spoolDrain) == 1)
        gate.open()
        await first.value
        #expect(work.calls(.spoolDrain) == 2)
    }

    @Test func eachNewStatusIsHandedToTheApp() async {
        let work = FakeWork()
        let changes = Changes()
        let hk = housekeeping(work, changes: changes)
        await hk.run(.backup)
        await hk.run(.agent)
        #expect(changes.all.count == 2)
        #expect(changes.all.last == hk.status)
        #expect(changes.all.first?.jobs[.agent] == JobHealth())
    }

    @Test func stopEndsTheLoopsAndTheSignal() async {
        let work = FakeWork()
        let signal = FakeSignal()
        let sleeper = ManualSleeper()
        let hk = housekeeping(work, signal: signal, sleeper: sleeper)
        hk.start()
        #expect(await eventually { sleeper.requested.count == 4 })
        hk.stop()
        #expect(!signal.started)
        sleeper.advance()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(work.calls(.spoolDrain) == 1)
    }

    // MARK: Through the real writer

    func home(collectors: [Config.Collector] = []) throws -> DayStoreLoaderTests.Home {
        let home = DayStoreLoaderTests.Home()
        var config = Config.defaults(timezone: "Asia/Kolkata")
        config.collectors = collectors
        try ConfigStore.save(config, to: home.roots.config)
        return home
    }

    final class CountingPoster: StoreChangePoster, @unchecked Sendable {
        private let lock = NSLock()
        private var posts = 0
        func postStoreChanged() { lock.withLock { posts += 1 } }
        var count: Int { lock.withLock { posts } }
    }

    /// Writes `ingest.run` events as a collector, at the clock's time.
    func record(
        _ runs: [(status: String, at: Date)], collector: String, in home: DayStoreLoaderTests.Home, clock: ManualClock
    ) throws {
        let config = try ConfigStore.load(from: home.roots.config, fallbackZone: "Asia/Kolkata").0
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 5))
        let store = try SQLiteStore(path: home.roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
        _ = try Journal(store: store, config: config, clock: clock, ids: ids)
        for run in runs {
            clock.set(run.at)
            let payload = IngestRun(
                collector: collector, since: "2026-10-27", until: "2026-10-29", counts: [:],
                errors: run.status == "error" ? ["exit status 1"] : [], status: run.status)
            _ = try store.append([EventPayload.ingestRun(payload).draft(actor: .collector(collector))])
        }
    }

    @Test func sourceHealthIsReadFromTheLedgerPerConfiguredCollector() async throws {
        let github = Config.Collector(name: "github", builtin: "github", gh: "/opt/homebrew/bin/gh", every: "30m")
        let transcripts = Config.Collector(name: "claude-code", builtin: "claude-code-transcripts", every: "60m")
        let off = Config.Collector(name: "usage", enabled: false, command: ["/usr/bin/true"], at: ["17:10"])
        let home = try home(collectors: [github, transcripts, off])
        defer { home.remove() }
        let clock = ManualClock(Self.at(13, 0))
        try record(
            [("ok", Self.at(13, 40)), ("error", Self.at(14, 10)), ("error", Self.at(14, 40)), ("error", Self.at(15, 10))],
            collector: "github", in: home, clock: clock)
        try record([("ok", Self.at(15, 0))], collector: "claude-code", in: home, clock: clock)

        clock.set(Self.at(15, 30))
        let writer = AppWriter(location: .found(home.roots), clock: clock, poster: CountingPoster())
        let sources = try await writer.collectorSources().get()

        // The disabled collector is not a source.
        #expect(sources.map(\.name) == ["claude-code", "github"])
        let gh = try #require(sources.first { $0.name == "github" })
        #expect(gh.failuresInARow == 3)
        #expect(gh.isFailing && gh.feedsCount && gh.isBehind)
        #expect(gh.lastGoodRun == Self.at(13, 40))
        #expect(gh.lastSync == "13:40")
        let ai = try #require(sources.first { $0.name == "claude-code" })
        #expect(!ai.isFailing && !ai.feedsCount)
        #expect(ai.lastGoodRun == Self.at(15, 0))
    }

    @Test func aCommandCollectorFeedsTheCountOnceItHasWrittenAnAcceptedItem() async throws {
        let tickets = Config.Collector(name: "tickets", command: ["/usr/bin/true"], every: "30m")
        let home = try home(collectors: [tickets])
        defer { home.remove() }
        let clock = ManualClock(Self.at(12, 0))
        let writer = AppWriter(location: .found(home.roots), clock: clock, poster: CountingPoster())
        #expect(try await writer.collectorSources().get().first?.feedsCount == false)

        let config = try ConfigStore.load(from: home.roots.config, fallbackZone: "Asia/Kolkata").0
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 9))
        let store = try SQLiteStore(path: home.roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids)
        let day = LocalDate("2026-10-29")!
        let entry = Entry(
            id: ids.next(), day: day.description, kind: .prMerged, family: .delivery, title: "Merged the retry budget",
            origin: .collected, source: "tickets", sourceRef: "tickets:1", status: .accepted)
        _ = try store.append([EventPayload.entryCreated(entry).draft(actor: .collector("tickets"))])
        _ = journal

        #expect(try await writer.collectorSources().get().first?.feedsCount == true)
    }

    func hookLine(_ event: String, session: String, at: String) -> String {
        #"{"at":"\#(at)","event":"\#(event)","session_id":"\#(session)","source":"startup","v":1,"project":"acme-service"}"#
    }

    @Test func drainingTheSpoolWritesSessionsAndPostsOnlyWhenRowsChanged() async throws {
        let home = try home()
        defer { home.remove() }
        let clock = ManualClock(Self.at(10, 0))
        let poster = CountingPoster()
        let writer = AppWriter(location: .found(home.roots), clock: clock, poster: poster)

        // An empty spool is a drain that did nothing, and nothing is announced.
        let empty = try await writer.drainSpool().get()
        #expect(empty.eventsWritten == 0)
        #expect(poster.count == 0)

        try FileManager.default.createDirectory(at: home.roots.spool, withIntermediateDirectories: true)
        let lines = [
            hookLine("session-start", session: "s1", at: "2026-10-29T09:00:00+05:30"),
            hookLine("session-end", session: "s1", at: "2026-10-29T09:40:00+05:30"),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: home.roots.spool.appendingPathComponent("hooks-2026-10-29.ndjson"))
        let report = try await writer.drainSpool().get()
        #expect(report.eventsWritten >= 1)
        #expect(poster.count == 1)

        // The same lines again write nothing.
        let again = try await writer.drainSpool().get()
        #expect(again.eventsWritten == 0)
        #expect(poster.count == 1)
    }

    @Test func theDailyBackupIsMadeOnceAndRetentionRunsEvenWhenItWasAlreadyMade() async throws {
        let home = try home()
        defer { home.remove() }
        let clock = ManualClock(Self.at(10, 0))
        let writer = AppWriter(location: .found(home.roots), clock: clock, poster: CountingPoster())
        // A store with at least the genesis event to back up.
        _ = try await writer.perform(.planAdd(title: "Review the ACME-101 change", day: nil)).get()

        let first = try await writer.runBackup().get()
        #expect(first.created)
        #expect(first.day == "2026-10-29")
        #expect((first.events ?? 0) >= 1)
        let file = home.roots.backups.appendingPathComponent("cadence-2026-10-29.db")
        #expect(FileManager.default.fileExists(atPath: file.path))

        // Fifteen older files, so the second run, which makes no backup, still has something to prune.
        for day in 1...15 {
            let name = String(format: "cadence-2026-09-%02d.db", day)
            try Data("x".utf8).write(to: home.roots.backups.appendingPathComponent(name))
        }
        let second = try await writer.runBackup().get()
        #expect(!second.created)
        #expect(second.pruned > 0)
    }

    @Test func aStoreThatCannotBeOpenedFailsEveryHousekeepingCall() async {
        let writer = AppWriter(
            location: .failed(StoreFailure(detail: "no home")), clock: ManualClock(Self.at(9, 0)), poster: CountingPoster())
        guard case .failure = await writer.drainSpool() else { Issue.record("expected a failure"); return }
        guard case .failure = await writer.runBackup() else { Issue.record("expected a failure"); return }
        guard case .failure = await writer.collectorSources() else { Issue.record("expected a failure"); return }
    }
}

/// One await that stays closed until the test opens it.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        for continuation in ready { continuation.resume() }
    }
}
