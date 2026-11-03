import CadenceCore
import Foundation
import Testing

@testable import CadenceMCP

/// plan_add, plan_update and declare_day (docs/SPEC.md section 9.2): accepted, written by actor mcp.
@Suite struct PlanToolTests {
    func planned(_ h: ToolHarness, _ titles: [String], date: String? = nil) throws -> [String] {
        var arguments: [String: JSONValue] = ["tasks": .array(titles.map { ["title": .string($0)] })]
        if let date { arguments["date"] = .string(date) }
        let reply = try h.call("plan_add", .object(arguments))
        #expect(!reply.isError, "\(reply.text)")
        return (reply.structured?["tasks"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }

    // MARK: plan_add

    @Test func tasksAreAddedToTodayAsSuggestedByTheAgent() throws {
        let h = try ToolHarness()
        let reply = try h.call(
            "plan_add",
            ["tasks": [["title": "Draft the idempotency ADR ACME-482913", "estimate_min": 60], ["title": "Review the retry PR"]]])
        #expect(!reply.isError)
        #expect(reply.text.hasPrefix("Planned for Thu 29 Oct: 2 tasks added.\n  1. Draft the idempotency ADR ACME-482913 (60m)  open  ["))
        #expect(reply.structured?["day"] == "2026-10-29")
        let tasks = try #require(reply.structured?["tasks"]?.arrayValue)
        #expect(tasks.map { $0["position"] } == [1, 2])
        #expect(tasks[0]["ticket"] == ["key": "ACME-482913", "class": "assigned"] && tasks[0]["estimate_min"] == 60)
        #expect(tasks.allSatisfy { $0["origin"] == "suggested" && $0["status"] == "open" })
        let events = try h.agentEvents().filter { $0.type == "plan.added" }
        #expect(events.count == 2 && events.allSatisfy { $0.actor == .mcp })
        #expect(try h.journal().dayView(ToolHarness.today).tasks.map(\.title) == ["Draft the idempotency ADR ACME-482913", "Review the retry PR"])
    }

    @Test func aDateCanBeGivenForAnotherDay() throws {
        let h = try ToolHarness()
        _ = try planned(h, ["Plan the migration"], date: "2026-10-30")
        let view = try h.journal().dayView(LocalDate("2026-10-30")!)
        #expect(view.tasks.map(\.title) == ["Plan the migration"])
        #expect(try h.journal().dayView(ToolHarness.today).tasks.isEmpty)
    }

    @Test func aBadTaskInTheListAddsNone() throws {
        let h = try ToolHarness()
        let before = try h.eventCount()
        let reply = try h.call("plan_add", ["tasks": [["title": "Fine task"], ["title": "   "]]])
        #expect(reply.isError && reply.rpcError == nil)
        #expect(reply.text == "Not done: title must not be empty")
        #expect(try h.eventCount() == before)
    }

    @Test func planAddRefusesBadInput() throws {
        let h = try ToolHarness()
        let many = (0..<21).map { JSONValue.object(["title": .string("Task \($0)")]) }
        let cases: [(JSONValue, String)] = [
            ([:], "Not done: tasks: is required."),
            (["tasks": []], "Not done: tasks: give at least one task"),
            (["tasks": .array(many)], "Not done: tasks: at most 20 items."),
            (["tasks": [["estimate_min": 5]]], "Not done: tasks[0].title: is required."),
            (["tasks": [["title": ""]]], "Not done: tasks[0].title: must be at least 1 characters."),
            (["tasks": [["title": "Task", "estimate_min": 0]]], "Not done: tasks[0].estimate_min: must be at least 1."),
            (["tasks": [["title": "Task", "estimate_min": 1441]]], "Not done: tasks[0].estimate_min: must be at most 1440."),
            (["tasks": [["title": "Task", "origin": "self"]]], "Not done: tasks[0].origin: is not a known argument."),
            (["tasks": [["title": "Task"]], "date": "tomorrow"], "Not done: date: must be a date as YYYY-MM-DD."),
        ]
        for (arguments, expected) in cases {
            let reply = try h.call("plan_add", arguments)
            #expect(reply.isError && reply.rpcError == nil, "\(arguments)")
            #expect(reply.text == expected, "\(arguments) gave \(reply.text)")
        }
        #expect(try h.agentEvents().filter { $0.type == "plan.added" }.isEmpty)
    }

    // MARK: plan_update

    @Test func aTaskIsResolvedDoneSlippedOrDropped() throws {
        let h = try ToolHarness()
        let ids = try planned(h, ["One", "Two", "Three"])
        let entry = try h.call("log_entry", ["text": "Finished the first thing"]).structured?["entry"]?["id"]?.stringValue ?? ""

        let done = try h.call("plan_update", ["task_id": .string(ids[0]), "status": "done", "entry_ids": [.string(entry)]])
        #expect(!done.isError)
        #expect(done.text.hasPrefix("Marked done: 1. One  done  ["))
        #expect(done.structured?["task"]?["status"] == "done")

        let slipped = try h.call("plan_update", ["task_id": .string(ids[1]), "status": "slipped", "reason": "reprioritised", "note": "moved to next week"])
        #expect(!slipped.isError && slipped.text.hasPrefix("Marked slipped: 2. Two  slipped: reprioritised  ["))
        #expect(slipped.structured?["task"]?["reason"] == "reprioritised")

        let dropped = try h.call("plan_update", ["task_id": .string(ids[2]), "status": "dropped", "reason": "no longer needed"])
        #expect(!dropped.isError && dropped.text.hasPrefix("Marked dropped: 3. Three  dropped: no longer needed  ["))

        let tasks = try h.journal().dayView(ToolHarness.today).tasks
        #expect(tasks.map(\.status) == [.done, .slipped, .dropped])
        #expect(tasks[0].linkedEntries == [entry] && tasks[1].reasonNote == "moved to next week")
        let resolved = try h.agentEvents().filter { $0.type == "plan.resolved" }
        #expect(resolved.count == 3 && resolved.allSatisfy { $0.actor == .mcp })
    }

    @Test func aSlipNeedsAReason() throws {
        let h = try ToolHarness()
        let id = try planned(h, ["Draft the ADR"])[0]
        let before = try h.eventCount()
        let reply = try h.call("plan_update", ["task_id": .string(id), "status": "slipped"])
        #expect(reply.isError && reply.rpcError == nil)
        #expect(reply.text == "Not done: a slipped task needs a reason")
        #expect(try h.eventCount() == before)
        #expect(try h.call("plan_update", ["task_id": .string(id), "status": "slipped", "reason": "  "]).isError)
        #expect(try h.journal().task(id).status == .open)
    }

    @Test func anOpenTaskCanBeEdited() throws {
        let h = try ToolHarness()
        let id = try planned(h, ["Draft the ADR"])[0]
        let reply = try h.call("plan_update", ["task_id": .string(id), "title": "Draft the idempotency ADR ACME-482913", "estimate_min": 90])
        #expect(!reply.isError)
        #expect(reply.text.hasPrefix("Updated: 1. Draft the idempotency ADR ACME-482913 (90m)  open  ["))
        let task = try h.journal().task(id)
        #expect(task.ticket == Ticket(key: "ACME-482913", class: .assigned) && task.estimateMin == 90 && task.origin == .suggested)
        let updates = try h.agentEvents().filter { $0.type == "plan.updated" }
        #expect(updates.count == 1 && updates[0].actor == .mcp && updates[0].subject == "task:\(id)")
        // An edit and a resolution in one call.
        let both = try h.call("plan_update", ["task_id": .string(id), "title": "Draft the ADR", "status": "done"])
        #expect(!both.isError && both.text.hasPrefix("Marked done: 1. Draft the ADR (90m)  done  ["))
        // A resolved task is not edited.
        let late = try h.call("plan_update", ["task_id": .string(id), "title": "Rewritten history"])
        #expect(late.isError && late.text.contains("only an open task can be edited"))
        #expect(try h.journal().task(id).title == "Draft the ADR")
    }

    @Test func aFailedResolutionTakesItsEditBackToo() throws {
        let h = try ToolHarness()
        let id = try planned(h, ["Draft the ADR"])[0]
        let before = try h.eventCount()
        let reply = try h.call("plan_update", ["task_id": .string(id), "title": "Changed title", "status": "done", "entry_ids": ["01NOSUCHENTRY"]])
        #expect(reply.isError && reply.text == "Not done: no entry with id 01NOSUCHENTRY")
        #expect(try h.eventCount() == before)
        #expect(try h.journal().task(id).title == "Draft the ADR")
    }

    @Test func planUpdateRefusesBadInput() throws {
        let h = try ToolHarness()
        let id = try planned(h, ["Draft the ADR"])[0]
        let before = try h.eventCount()
        let cases: [(JSONValue, String)] = [
            (["task_id": .string(id)], "Not done: give a status to resolve the task, or a title or estimate_min to edit it"),
            ([:], "Not done: task_id: is required."),
            (["task_id": "nope", "status": "done"], "Not done: no plan task with id nope"),
            (["task_id": .string(id), "status": "open"], "Not done: status: must be one of done, slipped, dropped."),
            (["task_id": .string(id), "status": "moved"], "Not done: status: must be one of done, slipped, dropped."),
            (["task_id": .string(id), "status": "done", "reason": "because"], "Not done: reason: only for a slipped or dropped task"),
            (["task_id": .string(id), "reason": "blocked", "title": "New"], "Not done: reason, note and entry_ids go with a status"),
            (["task_id": .string(id), "estimate_min": 0], "Not done: estimate_min: must be at least 1."),
            (["task_id": .string(id), "status": "done", "origin": "self"], "Not done: origin: is not a known argument."),
        ]
        for (arguments, expected) in cases {
            let reply = try h.call("plan_update", arguments)
            #expect(reply.isError && reply.rpcError == nil, "\(arguments)")
            #expect(reply.text == expected, "\(arguments) gave \(reply.text)")
        }
        #expect(try h.eventCount() == before)
    }

    @Test func aResolvedTaskCannotBeResolvedAgain() throws {
        let h = try ToolHarness()
        let id = try planned(h, ["Draft the ADR"])[0]
        #expect(!(try h.call("plan_update", ["task_id": .string(id), "status": "done"])).isError)
        let before = try h.eventCount()
        for arguments: JSONValue in [
            ["task_id": .string(id), "status": "done"], ["task_id": .string(id), "status": "dropped", "reason": "cancelled"],
            ["task_id": .string(id), "status": "slipped", "reason": "blocked"],
        ] {
            let reply = try h.call("plan_update", arguments)
            #expect(reply.isError && reply.rpcError == nil)
            #expect(reply.text == "Not done: task \(id) is already done; a resolved task is not resolved again", "\(reply.text)")
        }
        #expect(try h.eventCount() == before)
        #expect(try h.journal().task(id).status == .done)
    }

    @Test func aMovedTaskCannotBeResolvedOnItsOldDay() throws {
        let h = try ToolHarness()
        let id = try planned(h, ["Carry me"])[0]
        _ = try h.journal().seal(ToolHarness.today, actor: .cli)
        let reply = try h.call("plan_update", ["task_id": .string(id), "status": "done"])
        #expect(reply.isError && reply.text.contains("was carried to a later day"))
    }

    // MARK: declare_day

    @Test func aHolidayAndLeaveAreDeclaredByActorMcp() throws {
        let h = try ToolHarness()
        let holiday = try h.call("declare_day", ["date": "2026-10-30", "kind": "holiday", "label": "Founders day"])
        #expect(!holiday.isError)
        #expect(holiday.text == "Marked Fri 30 Oct as holiday: Founders day.")
        #expect(holiday.structured?["day"]?["kind"] == "holiday" && holiday.structured?["day"]?["label"] == "Founders day")
        let planned = try h.call("declare_day", ["date": "2026-10-23", "kind": "leave_planned"])
        #expect(planned.text == "Marked Fri 23 Oct as planned leave.")
        let unplanned = try h.call("declare_day", ["date": "2026-10-22", "kind": "leave_unplanned"])
        #expect(unplanned.text == "Marked Thu 22 Oct as unplanned leave.")
        let declared = try h.agentEvents().filter { $0.type == "day.declared" }
        #expect(declared.count == 3 && declared.allSatisfy { $0.actor == .mcp })
        #expect(try h.journal().dayView(LocalDate("2026-10-30")!).day.kind == .holiday)
    }

    @Test func declareDayRefusesWorkdaysAndUnknownKinds() throws {
        let h = try ToolHarness()
        let before = try h.eventCount()
        let cases: [(JSONValue, String)] = [
            (["date": "2026-10-30", "kind": "workday"], "Not done: kind: must be one of holiday, leave_planned, leave_unplanned."),
            (["date": "2026-10-30", "kind": "weekend"], "Not done: kind: must be one of holiday, leave_planned, leave_unplanned."),
            (["date": "2026-10-30"], "Not done: kind: is required."),
            (["kind": "holiday"], "Not done: date: is required."),
            (["date": "30 Oct", "kind": "holiday"], "Not done: date: must be a date as YYYY-MM-DD."),
            (["date": "2026-10-30", "kind": "holiday", "label": .string(String(repeating: "x", count: 101))], "Not done: label: must be at most 100 characters."),
        ]
        for (arguments, expected) in cases {
            let reply = try h.call("declare_day", arguments)
            #expect(reply.isError && reply.rpcError == nil, "\(arguments)")
            #expect(reply.text == expected, "\(arguments) gave \(reply.text)")
        }
        #expect(try h.eventCount() == before)
    }

    @Test func anAgentNeverReplacesADeclarationSomeoneElseMade() throws {
        let h = try ToolHarness()
        let journal = try h.journal()
        try journal.declare(LocalDate("2026-10-23")!, kind: .leavePlanned, label: "Family trip", actor: .cli)
        try journal.declare(LocalDate("2026-10-22")!, kind: .holiday, label: nil, actor: .app)
        try journal.declare(LocalDate("2026-10-21")!, kind: .leaveUnplanned, label: nil, actor: .collector("hr"))
        let before = try h.eventCount()
        for (date, who) in [("2026-10-23", "the user"), ("2026-10-22", "the user"), ("2026-10-21", "collector:hr")] {
            let reply = try h.call("declare_day", ["date": .string(date), "kind": "holiday", "label": "Overwritten"])
            #expect(reply.isError && reply.rpcError == nil, "\(date)")
            #expect(reply.text.hasPrefix("Not done: \(date) is already marked as "), "\(reply.text)")
            #expect(reply.text.hasSuffix(" by \(who); only the user can change it"), "\(reply.text)")
        }
        #expect(try h.eventCount() == before)
        let day = try journal.dayView(LocalDate("2026-10-23")!).day
        #expect(day.kind == .leavePlanned && day.label == "Family trip")

        // Its own declaration, and a day nobody declared, are still the agent's to set.
        let fresh = try h.call("declare_day", ["date": "2026-10-30", "kind": "holiday"])
        #expect(!fresh.isError)
        let again = try h.call("declare_day", ["date": "2026-10-30", "kind": "leave_planned", "label": "Corrected"])
        #expect(!again.isError && again.text == "Marked Fri 30 Oct as planned leave: Corrected.")
        // Once the user has changed it, the agent may not.
        try journal.declare(LocalDate("2026-10-30")!, kind: .holiday, label: "Founders day", actor: .cli)
        let late = try h.call("declare_day", ["date": "2026-10-30", "kind": "leave_unplanned"])
        #expect(late.isError && late.text.contains("already marked as holiday by the user"))
        #expect(try journal.dayView(LocalDate("2026-10-30")!).day.kind == .holiday)
    }

    // MARK: nothing else is written

    @Test func everyEventTheToolsWriteIsOneOfTheFiveAgentTypes() throws {
        let h = try ToolHarness()
        let ids = try planned(h, ["One", "Two"])
        _ = try h.call("log_entry", ["text": "Fixed a bug"])
        _ = try h.call("log_entry", ["text": "Paired on a fix", "date": "2026-10-28"])
        _ = try h.call("log_entries", ["transcript": "- Reviewed a doc", "dry_run": false])
        _ = try h.call("plan_update", ["task_id": .string(ids[0]), "status": "done"])
        _ = try h.call("plan_update", ["task_id": .string(ids[1]), "title": "Two, renamed"])
        _ = try h.call("declare_day", ["date": "2026-10-30", "kind": "holiday"])
        for tool in ["get_day", "query", "summary", "standup"] { _ = try h.call(tool) }
        let types = Set(try h.agentEvents().map(\.type))
        #expect(types.isSubset(of: ["ledger.genesis", "entry.created", "plan.added", "plan.updated", "plan.resolved", "day.declared"]))
        #expect(types.contains("entry.created") && types.contains("plan.resolved") && types.contains("day.declared"))
        // Nothing sealed, reopened, accepted, dismissed, checkpointed or changed in config, and every entry is the agent's.
        #expect(try h.events().allSatisfy { !["day.sealed", "day.reopened", "entry.status", "witness.checkpoint", "presence.span", "config.classifier"].contains($0.type) })
        let entries = try h.events().filter { $0.type == "entry.created" }.map { try Entry(json: $0.data) }
        #expect(entries.count == 3 && entries.allSatisfy { $0.origin == .agent })
        // The rebuild gives the same days back.
        let before = try h.journal().dayView(ToolHarness.today)
        try h.journal().store.rebuild()
        #expect(try h.journal().dayView(ToolHarness.today) == before)
    }
}
