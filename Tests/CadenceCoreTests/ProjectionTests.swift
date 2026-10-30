import Foundation
import Testing

@testable import CadenceCore

@Suite struct ProjectionTests {
    static let zone = "Asia/Kolkata"

    static func store(clock: ManualClock = ManualClock(TestStore.start)) throws -> SQLiteStore {
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        try store.ensureGenesis(profile: ["name": "Sample Person", "timezone": .string(zone)])
        return store
    }

    static func entry(_ id: String, day: String = "2026-10-29", title: String = "Fixed flaky ledger test", origin: Origin = .selfReported) -> Entry {
        Entry(
            id: id, day: day, kind: .workDone, family: .delivery, title: title, occurredAt: "2026-10-29T14:05:00+05:30",
            durationS: nil, quantity: 1, ticket: Ticket(key: "ACME-482913", class: .assigned), links: [], tags: ["quality"],
            attrs: [:], origin: origin, source: nil, sourceRef: nil, status: .accepted, backfilled: false, afterSeal: false,
            export: .include)
    }

    static func task(_ id: String, day: String = "2026-10-29", position: Int64 = 1) -> PlanTask {
        PlanTask(
            id: id, day: day, position: position, title: "Ship retry budget", ticket: nil, estimateMin: 60,
            origin: .selfReported, carriedFrom: nil, status: .open, reason: nil, reasonNote: nil, linkedEntries: [],
            plannedAt: "2026-10-29T10:05:00+05:30", resolvedAt: nil)
    }

    @Test func entriesTasksAndDaysProject() throws {
        let store = try Self.store()
        try store.append([
            EventPayload.dayStarted(DayMark(day: "2026-10-29", tz: Self.zone, at: "2026-10-29T10:02:00+05:30", source: .input)).draft(actor: .app),
            EventPayload.planAdded(Self.task("T1")).draft(actor: .cli),
            EventPayload.entryCreated(Self.entry("E1")).draft(actor: .cli),
            EventPayload.entryUpdated(Changes(fields: ["title": Change(old: "Fixed flaky ledger test", new: "Fixed the flaky ledger test")])).draft(actor: .cli, id: "E1"),
            EventPayload.planResolved(PlanResolved(status: .done, links: ["E1"])).draft(actor: .app, id: "T1"),
        ])
        let entry = try #require(try store.db.first("SELECT * FROM entries WHERE id = 'E1'"))
        #expect(entry.text("title") == "Fixed the flaky ledger test")
        #expect(entry.text("tags") == #"["quality"]"#)
        #expect(entry.text("origin") == "self")
        #expect(entry.int("created_seq") == 4)
        #expect(entry.int("updated_seq") == 5)
        let task = try #require(try store.db.first("SELECT * FROM plan_tasks WHERE id = 'T1'"))
        #expect(task.text("status") == "done")
        #expect(task.text("linked_entries") == #"["E1"]"#)
        #expect(task.text("resolved_at") == "2026-09-21T14:13:20.000Z")
        let day = try #require(try store.db.first("SELECT * FROM days WHERE date = '2026-10-29'"))
        #expect(day.text("tz") == Self.zone)
        #expect(day.text("first_activity") == "2026-10-29T10:02:00+05:30")
    }

    @Test func activityComparesInstantsNotText() throws {
        let store = try Self.store()
        try store.append([
            EventPayload.presenceSpan(PresenceSpanPayload(day: "2026-10-29", tz: Self.zone, start: "2026-10-29T10:00:00+05:30", end: "2026-10-29T12:00:00+05:30", source: .input)).draft(actor: .app),
            // 04:00Z is 09:30 in Kolkata: earlier, though its text sorts later.
            EventPayload.presenceSpan(PresenceSpanPayload(day: "2026-10-29", tz: Self.zone, start: "2026-10-29T04:00:00Z", end: "2026-10-29T05:00:00Z", source: .powerlog)).draft(actor: .app),
        ])
        let day = try #require(try store.db.first("SELECT * FROM days WHERE date = '2026-10-29'"))
        #expect(day.text("first_activity") == "2026-10-29T04:00:00Z")
        #expect(day.text("last_activity") == "2026-10-29T12:00:00+05:30")
        #expect(try store.db.query("SELECT id FROM presence_spans ORDER BY id").compactMap { $0.int("id") } == [2, 3])
    }

    @Test func sealRecordsTheEventHash() throws {
        let store = try Self.store()
        let head = try #require(try store.head()).hash
        let sealed = try store.append([
            EventPayload.daySealed(DaySealed(day: "2026-10-29", tz: Self.zone, counts: ["entries": 0], plan: PlanCounts(done: 0, slipped: 0, dropped: 0, moved: 0, open: 0), head: head)).draft(actor: .app)
        ])[0]
        let day = try #require(try store.db.first("SELECT * FROM days WHERE date = '2026-10-29'"))
        #expect(day.text("seal_event") == sealed.hash)
        #expect(day.text("sealed_at") == sealed.at)
    }

    @Test func genaiSessionsMergeStartAndEnd() throws {
        let store = try Self.store()
        try store.append([
            EventPayload.genaiSession(GenAISession(sessionId: "s1", tool: "claude-code", day: "2026-10-29", startedAt: "2026-10-29T10:00:00+05:30", endedAt: nil, endReason: nil, projectAlias: "ledger-core", models: [], turns: nil)).draft(actor: .hook),
            EventPayload.genaiSession(GenAISession(sessionId: "s1", tool: "claude-code", day: "2026-10-29", startedAt: "2026-10-29T10:00:00+05:30", endedAt: "2026-10-29T11:00:00+05:30", endReason: "exit", projectAlias: nil, models: ["model-a"], turns: 12)).draft(actor: .hook),
        ])
        let row = try #require(try store.db.first("SELECT * FROM genai_sessions WHERE session_id = 's1'"))
        #expect(row.text("project_alias") == "ledger-core")
        #expect(row.text("ended_at") == "2026-10-29T11:00:00+05:30")
        #expect(row.text("models") == #"["model-a"]"#)
        #expect(row.int("turns") == 12)
    }

    @Test func updatesToUnknownSubjectsRollBack() throws {
        let store = try Self.store()
        #expect(throws: CadenceError.self) {
            try store.append([EventPayload.entryStatus(EntryStatusChange(from: .accepted, to: .dismissed)).draft(actor: .cli, id: "NOPE")])
        }
        #expect(try store.eventCount() == 1)
    }

    @Test func unknownEventTypesAreIgnoredByProjections() throws {
        let store = try Self.store()
        try store.append([EventDraft(type: "future.thing", subject: nil, data: ["x": 1], actor: .app)])
        try store.rebuild()
        #expect(try store.eventCount() == 2)
    }

    // MARK: - Property test: live projections equal a rebuild, for random operation sequences

    struct Ops {
        let random: SeededRandomSource
        var entries: [String] = []
        var tasks: [String] = []
        var counter = 0

        init(seed: UInt64) { random = SeededRandomSource(seed: seed) }

        func pick(_ n: Int) -> Int { Int(random.bytes(2).reduce(0) { $0 << 8 | Int($1) }) % max(n, 1) }

        func day() -> String { ["2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30"][pick(4)] }

        func time(_ day: String) -> String {
            let h = 6 + pick(15), m = pick(60)
            return pick(3) == 0
                ? String(format: "%@T%02d:%02d:00Z", day, max(h - 6, 0), m)
                : String(format: "%@T%02d:%02d:00+05:30", day, h, m)
        }

        mutating func next(head: String) -> EventDraft {
            counter += 1
            let id = String(format: "X%05d", counter)
            switch pick(13) {
            case 0:
                let d = day()
                return EventPayload.dayStarted(DayMark(day: d, tz: zone, at: time(d), source: .input)).draft(actor: .app)
            case 1:
                let d = day()
                return EventPayload.presenceSpan(PresenceSpanPayload(day: d, tz: zone, start: time(d), end: time(d), source: .input)).draft(actor: .app)
            case 2:
                return EventPayload.dayDeclared(DayDeclared(day: day(), tz: zone, kind: DayKind.allCases[pick(DayKind.allCases.count)], label: pick(2) == 0 ? nil : "Leave")).draft(actor: .cli)
            case 3:
                return EventPayload.dayNoted(DayNoted(day: day(), tz: zone, focus: pick(2) == 0 ? nil : "retry budget", note: nil, onCall: pick(3) == 0 ? true : nil)).draft(actor: .cli)
            case 4, 5:
                entries.append(id)
                var e = ProjectionTests.entry(id, day: day(), title: "Entry \(counter)", origin: Origin.allCases[pick(4)])
                e.tags = pick(2) == 0 ? [] : ["t\(pick(3))"]
                return EventPayload.entryCreated(e).draft(actor: .cli)
            case 6 where !entries.isEmpty:
                let target = entries[pick(entries.count)]
                return EventPayload.entryUpdated(Changes(fields: [
                    "title": Change(old: "x", new: .string("Edited \(counter)")),
                    "tags": Change(old: [], new: ["edited"]),
                ])).draft(actor: .cli, id: target)
            case 7 where !entries.isEmpty:
                let target = entries[pick(entries.count)]
                return EventPayload.entryStatus(EntryStatusChange(from: .accepted, to: EntryStatus.allCases[pick(4)])).draft(actor: .cli, id: target)
            case 8:
                tasks.append(id)
                return EventPayload.planAdded(ProjectionTests.task(id, day: day(), position: Int64(pick(5) + 1))).draft(actor: .cli)
            case 9 where !tasks.isEmpty:
                let target = tasks[pick(tasks.count)]
                let status: TaskStatus = [.done, .slipped, .dropped, .open, .moved][pick(5)]
                return EventPayload.planResolved(PlanResolved(status: status, reason: status == .slipped ? "reprioritised" : nil, links: entries.isEmpty ? [] : [entries[0]])).draft(actor: .app, id: target)
            case 10 where !tasks.isEmpty:
                return EventPayload.planCommitted(PlanCommitted(day: day(), tz: zone, focus: "focus \(counter)", tasks: Array(tasks.suffix(3)))).draft(actor: .app)
            case 11:
                return EventPayload.daySealed(DaySealed(day: day(), tz: zone, counts: ["entries": Int64(entries.count)], plan: PlanCounts(done: 0, slipped: 0, dropped: 0, moved: 0, open: 0), head: head)).draft(actor: .app)
            default:
                let d = day()
                return EventPayload.genaiUsage(GenAIUsage(day: d, tool: "claude-code", model: ["model-a", "*"][pick(2)], source: ["endpoint", "transcripts"][pick(2)], sessions: Int64(pick(5)), requests: Int64(pick(200)), tokens: TokenCounts(input: 10, output: Int64(pick(1000)), cacheRead: nil, cacheWrite: 0), costMicros: nil, estimated: false)).draft(actor: .collector("claude-code"))
            }
        }
    }

    @Test(arguments: [UInt64(1), 2, 3, 42, 2026])
    func rebuildIsByteIdentical(seed: UInt64) throws {
        let clock = ManualClock(TestStore.start)
        let store = try Self.store(clock: clock)
        var ops = Ops(seed: seed)
        for _ in 0..<300 {
            clock.advance(by: 1.5)
            let head = try #require(try store.head()).hash
            try store.append([ops.next(head: head)])
        }
        let live = try store.projectionDump()
        #expect(live.split(separator: "\n").count > 20)
        try store.rebuild(batch: 37)
        #expect(try store.projectionDump() == live)

        // Replaying the same events into a brand-new store gives the same tables too.
        let fresh = try SQLiteStore(
            path: TestStore.tempDirectory().appendingPathComponent("cadence.db").path, clock: clock, ids: CountingIDs(),
            projector: LedgerProjector())
        let projector = LedgerProjector()
        let all = try store.events(after: 0, limit: 10_000)
        try fresh.transact { () throws(CadenceError) -> Void in
            for event in all { try projector.apply(event, in: fresh.db) }
        }
        #expect(try fresh.projectionDump() == live)
        #expect(try store.verifyChain().ok)
    }
}
