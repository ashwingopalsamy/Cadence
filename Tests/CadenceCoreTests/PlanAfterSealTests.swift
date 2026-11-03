import Foundation
import Testing

@testable import CadenceCore

/// Plan tasks added after their day's wrap-up carry an after-seal flag and are left out of plan done and plan accuracy
/// (docs/SPEC.md sections 3, 5.1 and 12.1, docs/PLAN.md T1.22). The flag is read from the ledger's order: a task is
/// after the seal when its `plan.added` event comes after the first `day.sealed` of its day.
@Suite struct PlanAfterSealTests {
    typealias F = DayMechanicsTests.Fixture

    /// Thu 29 Oct with two tasks done and slipped before the wrap-up and two more added after it.
    /// The clock stays on the 29th, so the day is sealed inside its grace window and counts.
    static func sealedDayWithLateTasks() throws -> (f: F, early: [PlanTask], late: [PlanTask]) {
        let f = try F()
        let a = try f.plan("Write ADR", on: "2026-10-29")
        let b = try f.plan("Draft design", on: "2026-10-29")
        _ = try f.journal.planResolve(taskID: a.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        _ = try f.journal.planResolve(taskID: b.id, status: .slipped, reason: "blocked", note: nil, links: [], actor: .cli)
        _ = try f.seal("2026-10-29")
        f.go("2026-10-29", 19, 5)
        let c = try f.plan("Late idea", on: "2026-10-29")
        let d = try f.plan("Another late idea", on: "2026-10-29")
        _ = try f.journal.planResolve(taskID: c.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        _ = try f.journal.planResolve(taskID: d.id, status: .slipped, reason: "reprioritised", note: nil, links: [], actor: .cli)
        return (f, [a, b], [c, d])
    }

    // MARK: the flag

    @Test func aTaskAddedAfterTheSealCarriesTheFlagAndOneAddedBeforeDoesNot() throws {
        let f = try F()
        let before = try f.plan("Before the wrap-up", on: "2026-10-29")
        #expect(!before.afterSeal)
        let carried = try f.seal("2026-10-29").carried
        f.go("2026-10-29", 19, 5)
        let after = try f.plan("After the wrap-up", on: "2026-10-29")
        #expect(after.afterSeal)
        // What was returned is what is read back.
        #expect(try f.journal.task(after.id) == after)
        #expect(try f.journal.task(after.id).afterSeal)
        #expect(!(try f.journal.task(before.id).afterSeal))
        #expect(try f.journal.dayView(f.day("2026-10-29")).tasks.map(\.afterSeal) == [false, true])
        // Another day is judged by its own seal: the 30th is not sealed, so a task added there is on time,
        // and the copy the seal carried to it was never after anything.
        let next = try f.plan("Next day", on: "2026-10-30")
        #expect(!next.afterSeal)
        #expect(carried.count == 1)
        #expect(!(try f.journal.task(try #require(carried.first).task.id).afterSeal))
        #expect(try f.journal.dayView(f.day("2026-10-30")).tasks.allSatisfy { !$0.afterSeal })
    }

    @Test func resolvingACarriedTaskAfterTheSealDoesNotMakeItLate() throws {
        let f = try F()
        let task = try f.plan("Planned in the morning", on: "2026-10-29")
        let carried = try #require(try f.seal("2026-10-29").carried.first).task
        f.go("2026-10-29", 21, 0)
        _ = try f.journal.planResolve(taskID: carried.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        #expect(!(try f.journal.task(task.id).afterSeal))
        #expect(!(try f.journal.task(carried.id).afterSeal))
    }

    @Test func aSecondSealNeverMovesTheBoundary() throws {
        let (store, clock) = try ProofExportTests.october()
        func add(_ id: String) throws {
            try store.append([
                EventPayload.planAdded(PlanTask(
                    id: id, day: "2026-10-28", position: 9, title: "Task \(id)", origin: .selfReported,
                    plannedAt: "2026-10-28T20:00:00+05:30")).draft(actor: .cli)
            ])
        }
        try add("L1")  // after the first seal of the 28th
        clock.set(Timestamp.parse("2026-10-30T05:00:00Z")!)
        try ProofExportTests.seal(store, "2026-10-28")  // a second seal, which the projection ignores
        try add("L2")
        let journal = try Journal(store: store, config: Config.defaults(timezone: ProofExportTests.zone), clock: clock, ids: CountingIDs())
        let tasks = try journal.dayView(LocalDate("2026-10-28")!).tasks
        #expect(Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.afterSeal) }) == ["T1": false, "T2": false, "L1": true, "L2": true])
    }

    @Test func theFlagIsReadFromTheLedgerSoItIsNotInAnyPayloadAndRebuildKeepsIt() throws {
        let (f, early, late) = try Self.sealedDayWithLateTasks()
        for task in early + late {
            let added = try #require(try f.journal.history(subject: "task:\(task.id)").first { $0.type == "plan.added" })
            #expect(added.data.objectValue?["after_seal"] == nil, "\(task.title)")
        }
        let live = try f.store.projectionDump()
        let version = try f.store.schemaVersion()
        try f.store.rebuild()
        #expect(try f.store.projectionDump() == live)
        #expect(try f.store.schemaVersion() == version)
        for task in late { #expect(try f.journal.task(task.id).afterSeal) }
        for task in early { #expect(!(try f.journal.task(task.id).afterSeal)) }
    }

    // MARK: plan done and plan accuracy

    @Test func summaryLeavesAfterSealTasksOutOfPlanDoneSlipsAndTheTotal() throws {
        let (f, _, _) = try Self.sealedDayWithLateTasks()
        let summary = try f.journal.summary(from: f.day("2026-10-29"), to: f.day("2026-10-29"))
        // One done and one slipped before the wrap-up. The late one done and the late one slipped are not in it.
        #expect(summary.planDone == 1)
        #expect(summary.planTotal == 2)
        #expect(summary.slipsByReason == ["blocked": 1])
        #expect(summary.planAfterSeal == 2)
        let json = try #require(summary.json.objectValue?["plan_done"]?.objectValue)
        #expect(json["value"] == 1 && json["of"] == 2 && json["after_seal"] == 2)
        #expect(json["definition"]?.stringValue?.contains("after") == true)
        #expect(SummaryRendering.human(summary).contains("Plan done"))
        #expect(SummaryRendering.human(summary).contains("2 added after wrap-up are not counted"))
    }

    @Test func aDayWithNoLateTasksReportsNoneLeftOutAndAnEmptyRangeIsUnknown() throws {
        let f = try F()
        let task = try f.plan("Only task", on: "2026-10-29")
        _ = try f.journal.planResolve(taskID: task.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        _ = try f.seal("2026-10-29")
        var summary = try f.journal.summary(from: f.day("2026-10-29"), to: f.day("2026-10-29"))
        #expect(summary.planDone == 1 && summary.planTotal == 1)
        #expect(summary.planAfterSeal == 0)
        #expect(!SummaryRendering.human(summary).contains("added after wrap-up"))
        // Only late tasks on the day: plan accuracy has nothing to measure, which is unknown and not 0 of 0.
        let g = try F()
        _ = try g.seal("2026-10-29")
        g.go("2026-10-29", 19, 5)
        _ = try g.plan("Late only", on: "2026-10-29")
        summary = try g.journal.summary(from: g.day("2026-10-29"), to: g.day("2026-10-29"))
        #expect(summary.planDone == nil && summary.planTotal == nil && summary.slipsByReason == nil)
        #expect(summary.planAfterSeal == 1)
        #expect(summary.json.objectValue?["plan_done"]?.objectValue?["value"] == .null)
    }

    @Test func theProofLeavesThemOutAndSaysHowManyAndAgreesWithTheSummary() throws {
        let (f, _, _) = try Self.sealedDayWithLateTasks()
        let request = ProofRequest(
            from: f.day("2026-10-29"), to: f.day("2026-10-29"), zone: DayMechanicsTests.zoneID, rules: DayRules(),
            generatedAt: f.clock.now())
        let proof = try ProofExporter.export(f.store, request)
        let plan = try #require(proof.json.objectValue?["summary"]?.objectValue?["plan_done"]?.objectValue)
        #expect(plan["value"] == 1)
        #expect(plan["of"] == 2)
        #expect(plan["after_seal"] == 2)
        #expect(plan["definition"]?.stringValue?.contains("after") == true)
        let summary = try f.journal.summary(from: f.day("2026-10-29"), to: f.day("2026-10-29"))
        let mine = try #require(summary.json.objectValue?["plan_done"]?.objectValue)
        #expect(mine["value"] == plan["value"] && mine["of"] == plan["of"] && mine["after_seal"] == plan["after_seal"])
        // The late tasks are still in the chain with their payloads, in order after the seal: nothing is hidden.
        let events = try #require(proof.json.objectValue?["chain"]?.objectValue?["events"]?.arrayValue).compactMap { $0.objectValue }
        let sealSeq = try #require(events.first { $0["type"] == "day.sealed" }?["seq"]?.intValue)
        let added = events.filter { $0["type"] == "plan.added" && $0["data"] != nil }
        #expect(added.count == 4)
        #expect(added.filter { ($0["seq"]?.intValue ?? 0) > sealSeq }.count == 2)
        #expect(try ProofExportTests.python(try ProofExportTests.write(proof.bytes)).status == 0)
    }

    @Test func aProofWithoutLateTasksReportsZeroLeftOut() throws {
        let (store, clock) = try ProofExportTests.october()
        let proof = try ProofExporter.export(store, ProofExportTests.request(clock))
        let plan = try #require(proof.json.objectValue?["summary"]?.objectValue?["plan_done"]?.objectValue)
        #expect(plan["value"] == 1 && plan["of"] == 2 && plan["after_seal"] == 0)
    }

    @Test func lateTasksOnASealedDayLeaveTheOctoberExampleAlone() throws {
        // The proof tests' October: T1 done and T2 open on the sealed 28th. Two tasks added later change nothing counted.
        let (store, clock) = try ProofExportTests.october()
        let before = try ProofExporter.export(store, ProofExportTests.request(clock))
        try store.append([
            EventPayload.planAdded(PlanTask(
                id: "L1", day: "2026-10-28", position: 3, title: "Added at night", origin: .selfReported,
                plannedAt: "2026-10-28T22:00:00+05:30")).draft(actor: .cli),
            EventPayload.planResolved(PlanResolved(status: .done)).draft(actor: .cli, id: "L1"),
        ])
        let after = try ProofExporter.export(store, ProofExportTests.request(clock))
        func plan(_ p: ProofFile) -> [JSONValue?] {
            let o = p.json.objectValue?["summary"]?.objectValue?["plan_done"]?.objectValue
            return [o?["value"], o?["of"], o?["after_seal"]]
        }
        #expect(plan(before) == [1, 2, 0])
        #expect(plan(after) == [1, 2, 1])
    }

    // MARK: how it reads

    @Test func theTaskLineAndTheJSONNameTheFlagWithoutTouchingTheLedgerShape() throws {
        let (f, early, late) = try Self.sealedDayWithLateTasks()
        let view = try f.journal.dayView(f.day("2026-10-29"))
        let lateTask = try #require(view.tasks.first { $0.id == late[0].id })
        let earlyTask = try #require(view.tasks.first { $0.id == early[0].id })
        #expect(Format.taskLine(lateTask).contains("after wrap-up"))
        #expect(!Format.taskLine(earlyTask).contains("after wrap-up"))
        #expect(lateTask.viewJSON.objectValue?["after_seal"] == true)
        #expect(earlyTask.viewJSON.objectValue?["after_seal"] == false)
        // The stored shape is unchanged: the payload of a plan.added never had the key.
        #expect(lateTask.json.objectValue?["after_seal"] == nil)
        let rendered = try #require(DayRendering.json(view).objectValue?["tasks"]?.arrayValue)
        #expect(rendered.allSatisfy { $0.objectValue?["after_seal"] != nil })
    }
}
