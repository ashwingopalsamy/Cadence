import AppKit
import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// A scripted run of several days against one real store, to find what only time finds (docs/SPEC.md sections 3 and 8).
///
/// One injected clock drives everything the app has: the reads, the writer, the presence pipeline and the day clock. The
/// run crosses 04:00 boundaries awake and asleep, a weekend, a time-zone change, a holiday and a leave day, seals one day
/// inside the grace window of the next, and carries and moves tasks. The app's writer takes bursts of log lines while
/// the real `cadence` binary, in child processes, writes to the same file. After every step `DayStoreLoader` reads the
/// day, and what it says has to agree with the ledger read independently: the day the clock and the zone name, every task and
/// entry of that day, the seal and the first activity, a ledger without gaps, and every line either writer was told
/// was saved. At the end the whole chain verifies, the day clock reported each boundary once and at the right instant,
/// no span crosses a boundary, and `cadence rebuild` gives byte for byte the projections the writers made.
///
/// `make check` runs a short version, a week, in a few seconds. `CADENCE_SOAK=1 swift test --filter SoakTests` runs the
/// long one: four weeks and thousands of writes.
@MainActor @Suite struct SoakTests {
    struct Scale: CustomStringConvertible {
        var name: String
        var days: Int
        var bursts: Int
        var linesPerBurst: Int
        var cliPerBurst: Int
        var description: String { name }

        static let short = Scale(name: "short", days: 7, bursts: 3, linesPerBurst: 8, cliPerBurst: 1)
        static let long = Scale(name: "long", days: 28, bursts: 4, linesPerBurst: 60, cliPerBurst: 2)
    }

    /// Thursday 8 Jan 2026, long past on any machine running this: the CLI child uses the real clock and may not write to a
    /// day that is still ahead of it. None of the three zones has a clock change in the weeks the run covers.
    static let first = LocalDate(soakFirstDay)!
    static let kolkata = "Asia/Kolkata"
    static let dubai = "Asia/Dubai"
    static let london = "Europe/London"

    @Test func aWeekAcrossBoundariesASleepAZoneChangeAndInterleavedWriters() async throws {
        try await Soak(scale: .short).run()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CADENCE_SOAK"] == "1", "set CADENCE_SOAK=1 for the long soak"))
    func fourWeeksAndThousandsOfWrites() async throws {
        try await Soak(scale: .long).run()
    }
}

// MARK: The run

/// The first day of the run, as text, for the code that reads the ledger off the main actor.
let soakFirstDay = "2026-01-08"

/// What the ledger says about a day, read on a connection of its own, in plain SQL.
struct SoakProbe: Sendable {
    var events: Int64
    var maxSeq: Int64
    var tasks: Int
    var accepted: Int
    var sealed: Bool
    var firstActivity: String?
    var appLines: Int
    var cliLines: Int

    static func read(_ roots: FileRoots, day: String) throws -> SoakProbe {
        let db = try SQLiteDatabase(path: roots.database.path, readOnly: true)
        func number(_ sql: String, _ arguments: [SQLValue] = []) throws -> Int64 {
            try db.first(sql, arguments)?.int("n") ?? -1
        }
        let row = try db.first("SELECT sealed_at, first_activity FROM days WHERE date = ?", [.text(day)])
        let lines = "json_extract(data, '$.title') LIKE 'Soak %'"
        return SoakProbe(
            events: try number("SELECT COUNT(*) AS n FROM events"), maxSeq: try number("SELECT COALESCE(MAX(seq), 0) AS n FROM events"),
            tasks: Int(try number("SELECT COUNT(*) AS n FROM plan_tasks WHERE day = ?", [.text(day)])),
            accepted: Int(try number("SELECT COUNT(*) AS n FROM entries WHERE day = ? AND status = 'accepted'", [.text(day)])),
            sealed: row?.text("sealed_at") != nil, firstActivity: row?.text("first_activity"),
            appLines: Int(try number("SELECT COUNT(*) AS n FROM events WHERE type = 'entry.created' AND actor = 'app' AND \(lines)")),
            cliLines: Int(try number("SELECT COUNT(*) AS n FROM events WHERE type = 'entry.created' AND actor = 'cli' AND \(lines)")))
    }
}

/// Passes presence events to the writer and adds up what each one wrote, to compare with the ledger.
final class PresenceTap: PresenceRecording, @unchecked Sendable {
    private let writer: AppWriter
    private let lock = NSLock()
    private var written = PresenceWrite.none

    init(_ writer: AppWriter) { self.writer = writer }

    var totals: PresenceWrite { lock.withLock { written } }

    func recordPresence(_ event: PresenceEvent, at instant: Date) async -> Result<PresenceWrite, StoreFailure> {
        let result = await writer.recordPresence(event, at: instant)
        lock.withLock {
            if case .success(let write) = result {
                written.spans += write.spans
                written.dayStarts += write.dayStarts
            }
        }
        return result
    }
}

@MainActor final class Soak {
    let scale: SoakTests.Scale
    let rig = StoreRig(decoys: false)
    let clock: ManualClock
    let sink = AppLogTests.CapturingLog()
    let app: AppState
    let poster = AppWriterTests.CountingPoster()
    let tap: PresenceTap
    let pipeline: PresencePipeline
    let timer = DayClockTests.FakeTimer()
    let center = NotificationCenter()
    let workspace = NotificationCenter()
    private(set) var dayClock: DayClock!
    private(set) var clockEvents: [DayClock.Event] = []

    var zoneID = SoakTests.kolkata
    var zone: TimeZone { TimeZone(identifier: zoneID)! }
    /// The instants the day clock must have reported as the start of a new day, with the zone each was read in.
    var expectedBoundaries: [Date] = []

    // What the run did, to compare with the ledger.
    var appLines = 0
    var cliLines = 0
    var busyRetries = 0
    var steps = 0
    var sleeps = 0
    var zoneChanges = 0
    var seals = 0
    var carriedTitles: [String] = []
    var lineNumber = 0
    var failures: [String] = []
    /// Lines the app's writer put on another day than the clock and the zone name, and days it recorded in another zone
    /// than the one in force when they began.
    var drift: [String] = []
    var zoneAtStart: [String: String] = [:]
    /// At the desk, input arrives every four minutes (the sampler's 30 s, thinned): under the engine's five-minute gap.
    var desk = false
    static let deskSampleSeconds: TimeInterval = 240

    init(scale: SoakTests.Scale) {
        self.scale = scale
        clock = ManualClock(Timestamp.parse("2026-01-08T08:30:00+05:30")!)
        let roots = rig.roots
        let loader = DayStoreLoader(location: .found(roots), clock: clock, log: sink)
        let writer = AppWriter(location: .found(roots), clock: clock, poster: poster, log: sink)
        app = AppState(model: DayModel(loader: loader), writer: writer, clock: clock)
        tap = PresenceTap(writer)
        pipeline = PresencePipeline(recorder: tap, clock: clock, retry: .standard, sleep: { _ in }, log: sink)
    }

    var roots: FileRoots { rig.roots }
    var loader: DayStoreLoader { DayStoreLoader(location: .found(roots), clock: clock) }

    // MARK: Time

    /// The instant "HH:MM" local on a workday; a time before the boundary belongs to the next calendar date.
    func at(_ day: LocalDate, _ time: String) -> Date {
        let hour = Int(time.prefix(2))!
        return Timestamp.instant(clockTime: time, on: hour < 4 ? day.adding(days: 1) : day, in: zone)!
    }

    /// Moves the clock to `target` awake. Every moment the day clock arms on the way goes off at its own time, and at
    /// the desk an active sample goes to the presence pipeline every four minutes.
    func advance(to target: Date) async {
        guard target > clock.now() else { return }
        var guardCount = 0
        while clock.now() < target, guardCount < 20_000 {
            guardCount += 1
            var step = desk ? min(target, clock.now().addingTimeInterval(Self.deskSampleSeconds)) : target
            if let next = timer.armedAt, next <= step { step = next.addingTimeInterval(0.02) }
            clock.set(step)
            if let next = timer.armedAt, next <= step {
                timer.fire()
                await react()
            }
            if desk { await typing() }
        }
        await react()
    }

    /// The Mac sleeps from `sleepAt` and wakes at `wakeAt`. Nothing runs in between; the wake is the day clock's signal.
    func sleep(from sleepAt: Date, to wakeAt: Date) async {
        await advance(to: sleepAt)
        await send(.sleep)
        let wakes = clockEvents.filter { $0 == .changed(.wake) }.count
        clock.set(wakeAt)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<400 where clockEvents.filter({ $0 == .changed(.wake) }).count == wakes { try? await Task.sleep(for: .milliseconds(5)) }
        await send(.wake)
        sleeps += 1
        await react()
    }

    private func startClock() {
        dayClock = DayClock(
            clock: clock, timer: timer, center: center, workspaceCenter: workspace,
            inputs: { [unowned self] in DayClockInput(location: .found(roots), state: app.model.state) },
            onEvent: { [unowned self] event in
                clockEvents.append(event)
                // As the app does, a moment or a change reads the day again.
                app.model.reload()
            })
        dayClock.start()
        dayClock.follow(app.model)
    }

    /// Lets the day clock's own signals and the model's reads settle.
    func react() async {
        try? await Task.sleep(for: .milliseconds(2))
    }

    func settle() async {
        await AppStateTests.settle(app)
    }

    // MARK: Writers

    func send(_ event: PresenceEvent) async {
        pipeline.submit(event)
        await pipeline.drain()
    }

    /// Active input at the current instant.
    func typing() async { await send(.sample(idleSeconds: 0, unlocked: true)) }

    /// A line through the app's writer. A busy store is tried again, once, as the person would press Try again.
    @discardableResult
    func line(_ text: String) async -> Entry? {
        for attempt in 0..<2 {
            let result = await app.writer.perform(.log(LogRequest(text: text)))
            switch result {
            case .success(.entry(let entry)):
                appLines += 1
                let expected = DayBoundary.standard.day(of: clock.now(), in: zone)
                if entry.day != expected.description { drift.append("\(text) landed on \(entry.day), the clock and zone say \(expected)") }
                return entry
            case .failure(let failure) where failure.kind == .busy && attempt == 0:
                busyRetries += 1
            case .failure(let failure):
                failures.append("line \(text): \(failure.kind) \(failure.detail)")
                return nil
            default:
                failures.append("line \(text): unexpected result")
                return nil
            }
        }
        return nil
    }

    func nextLine(_ who: String) -> String {
        lineNumber += 1
        return "Soak \(who) line \(lineNumber)"
    }

    /// The real `cadence log`, in a child process, for the day the clock names. A busy store is tried again, once.
    nonisolated static func cliLine(_ text: String, day: String, home: URL, userHome: URL) async throws -> Bool {
        for attempt in 0..<2 {
            do {
                try await CLIWriteLatencyTests.cli(["log", text, "--date", day], home: home, userHome: userHome)
                return attempt == 1
            } catch CLIWriteLatencyTests.LatencyError.failed(let status, let message) where status == 3 && attempt == 0 {
                _ = message  // exit status 3 is a busy store
            }
        }
        return true
    }

    /// A burst of lines through the writer while child processes write to the same file.
    func burst(_ lines: Int, who: String) async throws {
        let day = DayBoundary.standard.day(of: clock.now(), in: zone).description
        let home = roots.home
        let userHome = rig.base
        var children: [Task<Bool, Error>] = []
        var texts: [String] = []
        for _ in 0..<scale.cliPerBurst { texts.append(nextLine("cli")) }
        for text in texts {
            children.append(Task.detached { try await Soak.cliLine(text, day: day, home: home, userHome: userHome) })
        }
        for _ in 0..<lines { await line(nextLine(who)) }
        for child in children {
            if try await child.value { busyRetries += 1 }
            cliLines += 1
        }
    }

    // MARK: Checks

    /// What `DayStoreLoader` says now has to agree with the ledger.
    func check(_ step: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        steps += 1
        let loader = loader
        var load = await Task.detached { loader.load() }.value
        if case .failed(let failure) = load, failure.kind == .busy {
            busyRetries += 1
            load = await Task.detached { loader.load() }.value
        }
        guard FileManager.default.fileExists(atPath: roots.database.path) else {
            guard case .failed(let failure) = load else {
                #expect(Bool(false), "\(step): a store that does not exist loaded", sourceLocation: sourceLocation)
                return
            }
            #expect(failure.kind == .missing, "\(step)", sourceLocation: sourceLocation)
            return
        }
        guard case .loaded(let state) = load, let context = state.context else {
            #expect(Bool(false), "\(step): the read failed: \(load)", sourceLocation: sourceLocation)
            return
        }
        let expected = DayBoundary.standard.day(of: clock.now(), in: zone)
        #expect(state.day == expected, "\(step): the read is for \(state.day), the clock and zone say \(expected)", sourceLocation: sourceLocation)
        let roots = roots
        let day = state.day.description
        let probe = try await Task.detached { try SoakProbe.read(roots, day: day) }.value
        #expect(context.view.tasks.count == probe.tasks, "\(step): tasks", sourceLocation: sourceLocation)
        #expect(context.found.count == probe.accepted, "\(step): entries", sourceLocation: sourceLocation)
        #expect(state.isSealed == probe.sealed, "\(step): sealed", sourceLocation: sourceLocation)
        #expect(state.startedAt == probe.firstActivity.flatMap { Timestamp.parse($0) }, "\(step): first activity", sourceLocation: sourceLocation)
        #expect(probe.events == probe.maxSeq, "\(step): the ledger has a gap", sourceLocation: sourceLocation)
        #expect(probe.appLines == appLines, "\(step): lines the app wrote and the ledger holds", sourceLocation: sourceLocation)
        #expect(probe.cliLines == cliLines, "\(step): lines the CLI wrote and the ledger holds", sourceLocation: sourceLocation)
        if !failures.isEmpty {
            #expect(Bool(false), "\(step): \(failures)", sourceLocation: sourceLocation)
            failures = []
        }
    }

    func resolve(_ title: String?, as status: TaskStatus) async -> Bool {
        guard let task = app.context?.plan.first(where: { $0.status == .open && (title == nil || $0.title == title) }) else { return false }
        return await app.resolve(task.id, as: status, reason: status == .slipped ? "reprioritised" : nil)
    }

    // MARK: The days

    func run() async throws {
        defer { rig.remove() }
        try ConfigStore.save(Config.defaults(timezone: SoakTests.kolkata), to: roots.config)
        startClock()
        let started = ContinuousClock.now
        var day = SoakTests.first
        // The first read finds no store: a first run.
        await settle()
        try await check("before the first write")
        #expect(app.model.failure?.kind == .missing)

        for index in 0..<scale.days {
            try await script(day, index: index)
            day = day.adding(days: 1)
        }
        await finish(started: started)
    }

    /// The zone the run moves to next: Kolkata to Dubai, whose 04:00 comes 90 minutes later in UTC, then to London.
    var nextZone: String? {
        switch zoneID {
        case SoakTests.kolkata: SoakTests.dubai
        case SoakTests.dubai: SoakTests.london
        default: nil
        }
    }

    func boundaryCount() -> Int {
        clockEvents.filter { if case .moment(let moment) = $0, moment.kind == .boundary { true } else { false } }.count
    }

    /// Everything one calendar day holds, by its place in the week. Thursday 8 Jan is the first.
    func script(_ day: LocalDate, index: Int) async throws {
        let weekday = day.weekday
        let label = "\(day) \(weekday)"
        expectedBoundaries.append(DayBoundary.standard.interval(of: day, in: zone).start)

        if weekday == .sat || weekday == .sun {
            await advance(to: at(day, "10:00"))
            if weekday == .sat {
                // Saturday morning is still inside Friday's grace window: Friday is wrapped up late.
                let friday = day.adding(days: -1)
                await settle()
                try await check("\(label) before the late seal")
                guard let sealed = await app.seal(day: friday, standup: true) else {
                    #expect(Bool(false), "\(label): the late seal did not land")
                    return
                }
                seals += 1
                carriedTitles = sealed.sealed.carried.map(\.task.title)
                #expect(sealed.sealed.day == friday)
                #expect(sealed.standup?.isEmpty == false)
                await settle()
                #expect(app.state?.day == day, "\(label): the day on screen after sealing Friday")
                try await check("\(label) after the late seal")
            }
            await advance(to: at(day, "22:00"))
            try await check("\(label) evening")
            return
        }

        // The person arrives, and the day starts from the first input.
        zoneAtStart[day.description] = zoneID
        await advance(to: at(day, "09:00"))
        desk = true
        await typing()
        await settle()
        try await check("\(label) first input")
        #expect(app.state?.startedAt != nil)

        // Carried tasks wait outside the plan until the morning plan is committed.
        if !carriedTitles.isEmpty {
            let titles = app.context?.carried.map(\.title) ?? []
            #expect(Set(titles) == Set(carriedTitles), "\(label): carried tasks waiting \(titles), expected \(carriedTitles)")
        }

        // Days off.
        if weekday == .mon {
            #expect(await app.declare(.holiday))
            await settle()
            #expect(app.state?.kind == .holiday)
            try await check("\(label) declared a holiday")
            #expect(await app.workingAfterAll())
            await settle()
            #expect(app.state?.kind == .workday)
            try await check("\(label) working after all")
        }
        if weekday == .tue && index % 7 == 5 {
            #expect(await app.declare(.leave))
            await settle()
            #expect(app.state?.kind == .leaveUnplanned)
            try await check("\(label) declared leave")
            // What was carried here stays here: a leave day is never wrapped up.
            carriedTitles = []
            await leaveTheDesk()
            await advance(to: at(day, "23:30"))
            return
        }

        // The morning plan: pick one carried task, add three.
        await advance(to: at(day, "09:05"))
        let waiting = app.context?.carried ?? []
        let picked = Array(waiting.prefix(1).map(\.id))
        let added = ["one", "two", "three"].map { "Soak plan \($0) \(index)" }
        #expect(await app.commitPlan(picked: picked, added: added, focus: "Soak focus \(index)"))
        carriedTitles = []
        await settle()
        #expect(app.context?.committed == true)
        // The carried tasks that were not picked are dropped and left out of the plan; the plan is what was picked and added.
        #expect(app.context?.plan.count == picked.count + added.count)
        #expect(app.context?.view.tasks.filter { $0.status == .dropped && $0.origin == .carried }.count ?? 0 >= waiting.count - picked.count)
        try await check("\(label) plan committed")

        // Work in bursts, with the zone change at 12:30 on the first Monday (and once more in the long run) and a lunch
        // away from the desk. Every time in the day is the wall clock of the zone then in force.
        let burstTimes = ["10:00", "11:30", "14:30", "16:00"].prefix(scale.bursts)
        let zoneChange = index == 4 || (scale.days > 14 && index == scale.days * 2 / 3)
        for (number, time) in burstTimes.enumerated() {
            if time == "14:30" {
                if zoneChange, let next = nextZone {
                    await advance(to: at(day, "12:30"))
                    try await changeZone(to: next, label: label)
                }
                await advance(to: at(day, "13:00"))
                desk = false
                await send(.lock)
                await advance(to: at(day, "14:00"))
                await send(.unlock)
                desk = true
                await typing()
            }
            await advance(to: at(day, time))
            try await burst(scale.linesPerBurst, who: "app")
            if number == 0 { _ = await resolve(nil, as: .done) }
            await settle()
            try await check("\(label) burst \(number)")
        }

        await advance(to: at(day, "17:30"))
        await leaveTheDesk()
        if weekday == .fri {
            // Friday is left open for the night and wrapped up on Saturday, inside the grace window.
            try await check("\(label) wrap-up reminder")
            try await overnightAwake(day, label: label)
            return
        }
        try await wrapUp(day, label: label)

        // After a zone change the night is spent awake, with a night owl in the hours between the two zones' 04:00.
        if zoneChange {
            try await overnightAwake(day, label: label)
            return
        }

        // The Mac sleeps through the next 04:00 on some evenings.
        if index % 3 == 0 && index < scale.days - 1 {
            let before = boundaryCount()
            await sleep(from: at(day, "23:30"), to: at(day.adding(days: 1), "07:00"))
            await settle()
            #expect(boundaryCount() == before + 1, "\(label): the boundary slept through was reported \(boundaryCount() - before) times")
            try await check("\(label) after the sleep")
        }
    }

    /// Wrap-up as the sheet does it: a task moved to tomorrow with its reason, another ticked, a stand-up, and a seal that
    /// carries what is still open.
    func wrapUp(_ day: LocalDate, label: String) async throws {
        await settle()
        var carried: [String] = []
        if let first = app.context?.plan.first(where: { $0.status == .open }) {
            #expect(await app.move(first.id, reason: .reprioritised))
            carried.append(first.title)
            await settle()
            try await check("\(label) one task moved")
            #expect(app.context?.plan.first(where: { $0.id == first.id })?.status == .slipped)
        }
        _ = await resolve(nil, as: .done)
        await settle()
        let remaining = (app.context?.plan ?? []).filter { $0.status == .open }.map(\.title)
        carried += remaining
        guard let sealed = await app.seal(standup: true) else {
            #expect(Bool(false), "\(label): the seal did not land")
            return
        }
        seals += 1
        await settle()
        #expect(app.state?.isSealed == true)
        #expect(Set(sealed.sealed.carried.map(\.task.title)) == Set(remaining), "\(label): the seal carried the open tasks")
        carriedTitles = carried
        try await check("\(label) sealed")
    }

    /// Hands off the keyboard: the next sample says the input stopped five minutes ago, which closes the span there.
    func leaveTheDesk() async {
        desk = false
        await send(.sample(idleSeconds: 400, unlocked: true))
    }

    /// Friday night with the Mac awake and idle until a night owl types from 03:00 to 05:00, across the boundary.
    func overnightAwake(_ day: LocalDate, label: String) async throws {
        var cursor = at(day, "18:00")
        while cursor < at(day, "02:30") {
            await advance(to: cursor)
            // Awake and untouched since 17:25: the idle time keeps growing, and no new day is started by it.
            await send(.sample(idleSeconds: cursor.timeIntervalSince(at(day, "17:25")), unlocked: true))
            cursor = cursor.addingTimeInterval(30 * 60)
        }
        await advance(to: at(day, "03:00"))
        desk = true
        await typing()
        // 03:00 on the wall clock: before the boundary, so still this workday.
        try await burst(2, who: "owl")
        await settle()
        try await check("\(label) night owl")
        await advance(to: at(day.adding(days: 1), "05:00"))
        await leaveTheDesk()
        await advance(to: at(day.adding(days: 1), "06:00"))
        await settle()
        try await check("\(label) after the boundary")
    }

    func changeZone(to newID: String, label: String) async throws {
        zoneID = newID
        try ConfigStore.save(Config.defaults(timezone: newID), to: roots.config)
        let before = clockEvents.filter { $0 == .changed(.timeZone) }.count
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        for _ in 0..<400 where clockEvents.filter({ $0 == .changed(.timeZone) }).count == before { try? await Task.sleep(for: .milliseconds(5)) }
        zoneChanges += 1
        #expect(clockEvents.filter { $0 == .changed(.timeZone) }.count == before + 1, "\(label): the zone change was not reported once")
        await settle()
        try await check("\(label) after the zone change to \(newID)")
    }

    // MARK: The end

    func finish(started: ContinuousClock.Instant) async {
        await settle()
        await pipeline.stop()
        dayClock.stop()
        let elapsed = started.duration(to: .now)
        let rig = rig
        let roots = roots
        let now = clock.now()
        let outcome: Outcome? = await Task.detached { try? Soak.verifyEnd(rig: rig, roots: roots, now: now) }.value
        #expect(outcome != nil, "the end could not be read")
        guard let outcome else { return }
        #expect(outcome.chainOK, "the hash chain does not verify")
        #expect(outcome.rebuildIdentical, "cadence rebuild changed the projections")
        #expect(outcome.chainAfterRebuild)
        #expect(outcome.stateBefore == outcome.stateAfter, "the day read after the rebuild differs from the day read before it")
        #expect(outcome.crossingSpans.isEmpty, "spans cross a day boundary: \(outcome.crossingSpans)")
        #expect(outcome.appLines == appLines && outcome.cliLines == cliLines, "lines saved \(appLines) + \(cliLines), ledger holds \(outcome.appLines) + \(outcome.cliLines)")
        #expect(outcome.events >= Int64(poster.count + cliLines), "fewer events than commits")
        #expect(outcome.presenceSpansByApp == tap.totals.spans, "spans the writer reported \(tap.totals.spans), the ledger holds \(outcome.presenceSpansByApp)")
        #expect(outcome.dayStartsByApp == tap.totals.dayStarts, "day starts the writer reported \(tap.totals.dayStarts), the ledger holds \(outcome.dayStartsByApp)")
        #expect(tap.totals.spans > 0 && tap.totals.dayStarts > 0)
        for (day, zone) in zoneAtStart.sorted(by: { $0.key < $1.key }) where outcome.dayZones[day] != zone {
            drift.append("\(day) began in \(zone) and was recorded in \(outcome.dayZones[day] ?? "no zone")")
        }
        if !failures.isEmpty { #expect(Bool(false), "\(failures)") }
        // The writer now follows a zone change at once. What remains is the presence engine's calendar rule: a day ends at
        // 04:00 in its own zone, so a night owl past the old zone's 04:00 starts the next day, and that day is created in
        // the old zone. A decision for the presence engine (a starred module), recorded in docs/decisions.
        withKnownIssue("a day started by a presence span after a zone change is recorded in the previous day's zone") {
            #expect(drift.isEmpty, "\(drift)")
        }

        // The day clock named every boundary once, at 04:00 of the day it began, in the zone then in force.
        let reported = clockEvents.compactMap { event -> Date? in
            if case .moment(let moment) = event, moment.kind == .boundary { return moment.at }
            return nil
        }
        let wanted = Set(expectedBoundaries.dropFirst())
        #expect(Set(reported).count == reported.count, "a boundary was reported twice")
        #expect(Set(reported) == wanted, "boundaries never reported: \(wanted.subtracting(reported).sorted()); reported that no day began at: \(Set(reported).subtracting(wanted).sorted())")
        #expect(clockEvents.filter { $0 == .changed(.wake) }.count == sleeps)
        #expect(clockEvents.filter { $0 == .changed(.timeZone) }.count == zoneChanges)

        print(
            "T4.14 soak \(scale): \(scale.days) days, \(steps) checks, \(poster.count) commits by the app (\(appLines) lines), \(cliLines) lines by the CLI, \(outcome.events) events, \(outcome.spans) presence spans, \(seals) seals, \(sleeps) sleeps across a boundary, \(zoneChanges) zone changes, \(reported.count) boundaries reported, \(busyRetries) busy retries, chain ok \(outcome.chainOK), rebuild identical \(outcome.rebuildIdentical), \(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))"
        )
    }

    struct Outcome: Sendable {
        var chainOK: Bool
        var problems: [String]
        var events: Int64
        var spans: Int
        var rebuildIdentical: Bool
        var chainAfterRebuild: Bool
        var stateBefore: DayLoad
        var stateAfter: DayLoad
        var crossingSpans: [String]
        var appLines: Int
        var cliLines: Int
        var dayZones: [String: String]
        var presenceSpansByApp: Int
        var dayStartsByApp: Int
    }

    /// The chain, the spans, and `cadence rebuild` against the projections the writers made.
    nonisolated static func verifyEnd(rig: StoreRig, roots: FileRoots, now: Date) throws -> Outcome {
        let before = try StoreRig.snapshot(of: roots)
        let clock = ManualClock(now)
        let probe = try SoakProbe.read(roots, day: soakFirstDay)
        let loaderBefore = DayStoreLoader(location: .found(roots), clock: clock).load()
        try runRebuild(rig: rig, roots: roots)
        let after = try StoreRig.snapshot(of: roots)
        let loaderAfter = DayStoreLoader(location: .found(roots), clock: clock).load()

        let db = try SQLiteDatabase(path: roots.database.path, readOnly: true)
        var zones: [String: TimeZone] = [:]
        for row in try db.query("SELECT date, tz FROM days") {
            if let date = row.text("date"), let tz = row.text("tz"), let zone = TimeZone(identifier: tz) { zones[date] = zone }
        }
        var crossing: [String] = []
        let spans = try db.query("SELECT day, start_at, end_at FROM presence_spans")
        for row in spans {
            guard let day = row.text("day"), let zone = zones[day], let start = row.text("start_at").flatMap({ Timestamp.parse($0) }),
                let end = row.text("end_at").flatMap({ Timestamp.parse($0) })
            else {
                crossing.append("unreadable span")
                continue
            }
            let first = DayBoundary.standard.day(of: start, in: zone).description
            let last = DayBoundary.standard.day(of: end.addingTimeInterval(-0.5), in: zone).description
            if first != day || last != day || end < start { crossing.append("\(day): \(row.text("start_at") ?? "") to \(row.text("end_at") ?? "")") }
        }
        let presenceSpans = try db.first("SELECT COUNT(*) AS n FROM events WHERE type = 'presence.span' AND actor = 'app'")?.int("n") ?? -1
        let dayStarts = try db.first("SELECT COUNT(*) AS n FROM events WHERE type = 'day.started' AND actor = 'app'")?.int("n") ?? -1
        let dayZones = zones.mapValues(\.identifier)
        return Outcome(
            chainOK: before.chainOK, problems: [], events: before.events, spans: spans.count,
            rebuildIdentical: before.projections == after.projections && before.events == after.events && before.head == after.head,
            chainAfterRebuild: after.chainOK, stateBefore: loaderBefore, stateAfter: loaderAfter, crossingSpans: crossing,
            appLines: probe.appLines, cliLines: probe.cliLines, dayZones: dayZones, presenceSpansByApp: Int(presenceSpans),
            dayStartsByApp: Int(dayStarts))
    }

    nonisolated static func runRebuild(rig: StoreRig, roots: FileRoots) throws {
        let process = Process()
        process.executableURL = try CLIWriteLatencyTests.binary()
        process.arguments = ["rebuild"]
        var environment = ProcessInfo.processInfo.environment
        environment["CADENCE_HOME"] = roots.home.path
        environment["HOME"] = rig.base.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CadenceError.io("cadence rebuild failed: \(text)") }
    }
}
