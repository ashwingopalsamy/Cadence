import Foundation
import Testing

@testable import CadenceCore

/// What the MCP server needs from the journal (docs/SPEC.md section 9.2): proposals that land in the Inbox, a
/// preview that writes nothing, many entries in one transaction, plan edits and a stand-up that only reads.
@Suite struct AgentWritesTests {
    /// Thursday 2026-10-29, 18:00 in Kolkata.
    typealias Fixture = DayMechanicsTests.Fixture

    // MARK: proposed and dictated entries

    @Test func aProposedRequestLandsInTheInboxEvenForToday() throws {
        let f = try Fixture()
        let entry = try f.journal.log(
            LogRequest(text: "Reviewed ACME-482913 retry budget", proposed: true), actor: .mcp, origin: .agent)
        #expect(entry.status == .proposed)
        #expect(entry.day == "2026-10-29" && !entry.backfilled)
        #expect(entry.origin == .agent)
        #expect(try f.journal.inbox().map(\.id) == [entry.id])
        // The same request without the flag is accepted for today.
        let plain = try f.journal.log(LogRequest(text: "Fixed a flaky test"), actor: .mcp, origin: .agent)
        #expect(plain.status == .accepted)
    }

    @Test func aDictatedRequestIsMarkedAndKeepsItsOrigin() throws {
        let f = try Fixture()
        let entry = try f.journal.log(
            LogRequest(text: "Paired on the capture path", date: f.day("2026-10-28"), proposed: true, dictated: true),
            actor: .mcp, origin: .agent)
        #expect(entry.attrs["dictated"] == .bool(true))
        #expect(entry.origin == .agent && entry.status == .proposed && entry.backfilled)
        #expect(try f.journal.entry(entry.id) == entry)
        // Accepting it later never changes who wrote it.
        let accepted = try f.journal.setStatus(entryID: entry.id, to: .accepted, note: nil, actor: .cli)
        #expect(accepted.origin == .agent && accepted.attrs["dictated"] == .bool(true))
        let plain = try f.journal.log(LogRequest(text: "Wrote an ADR"), actor: .cli, origin: .selfReported)
        #expect(plain.attrs["dictated"] == nil)
    }

    // MARK: preview

    @Test func aPreviewShowsWhatLogWouldRecordAndWritesNothing() throws {
        let f = try Fixture()
        let request = LogRequest(text: "Merged ACME-482913 retry budget at 10:30 ~45m", proposed: true)
        let before = try f.store.eventCount()
        let preview = try f.journal.preview(request, origin: .agent)
        #expect(try f.store.eventCount() == before)
        #expect(preview.id == "")
        let logged = try f.journal.log(request, actor: .mcp, origin: .agent)
        var expected = logged
        expected.id = ""
        #expect(preview == expected)
        #expect(try f.store.eventCount() == before + 1)
    }

    @Test func aPreviewRefusesWhatLogRefuses() throws {
        let f = try Fixture()
        let before = try f.store.eventCount()
        for request in [
            LogRequest(text: "  "), LogRequest(text: "Fixed it", date: f.day("2026-10-30")),
            LogRequest(text: "Fixed it", links: [Link(kind: .other, url: "http://example.com/x")]),
        ] {
            #expect(throws: CadenceError.self) { try f.journal.preview(request, origin: .agent) }
            #expect(throws: CadenceError.self) { try f.journal.log(request, actor: .mcp, origin: .agent) }
        }
        #expect(try f.store.eventCount() == before)
    }

    @Test func aPreviewKnowsASealedDay() throws {
        let f = try Fixture()
        _ = try f.journal.seal(f.day("2026-10-29"), actor: .cli)
        let preview = try f.journal.preview(LogRequest(text: "Fixed a late bug"), origin: .agent)
        #expect(preview.afterSeal)
    }

    // MARK: many entries

    @Test func logAllLandsEveryEntryOrNone() throws {
        let f = try Fixture()
        let good = [
            LogRequest(text: "Reviewed a design doc", proposed: true), LogRequest(text: "Fixed a flaky test", proposed: true),
        ]
        let before = try f.store.eventCount()
        let entries = try f.journal.logAll(good, actor: .mcp, origin: .agent)
        #expect(entries.count == 2 && entries.allSatisfy { $0.status == .proposed && $0.origin == .agent })
        #expect(Set(entries.map(\.id)).count == 2)
        #expect(try f.store.eventCount() == before + 2)

        let bad = good + [LogRequest(text: "From the future", date: f.day("2026-11-02"))]
        #expect(throws: CadenceError.self) { try f.journal.logAll(bad, actor: .mcp, origin: .agent) }
        #expect(try f.store.eventCount() == before + 2)
        #expect(try f.journal.inbox().count == 2)
    }

    // MARK: transcripts

    @Test func aTranscriptBecomesProposedDictatedRequests() throws {
        let f = try Fixture()
        let text = """
            Wed 28 Oct
            - Reviewed settlement batching RFC ACME-482913
            • Paired on the flaky ledger test ~1h
            Thu 22 Oct
            - Raised retry storms in arch sync @10:30
            """
        let requests = f.journal.requests(fromTranscript: text, date: nil)
        #expect(requests.map(\.text) == [
            "Reviewed settlement batching RFC ACME-482913", "Paired on the flaky ledger test ~1h",
            "Raised retry storms in arch sync @10:30",
        ])
        #expect(requests.map(\.date) == [f.day("2026-10-28"), f.day("2026-10-28"), f.day("2026-10-22")])
        #expect(requests.allSatisfy { $0.proposed && $0.dictated })
        let entries = try f.journal.logAll(requests, actor: .mcp, origin: .agent)
        #expect(entries.map(\.day) == ["2026-10-28", "2026-10-28", "2026-10-22"])
        #expect(entries.map(\.status) == [.proposed, .proposed, .proposed])
        #expect(entries[1].durationS == 3600)
        #expect(entries[2].occurredAt?.hasPrefix("2026-10-22T10:30") == true)
    }

    @Test func theGivenDateIsForLinesThatNameNoDay() throws {
        let f = try Fixture()
        let text = "- Reviewed a design doc\n- Fixed a test yesterday\n- Led a retro at 11:00"
        let requests = f.journal.requests(fromTranscript: text, date: f.day("2026-10-27"))
        // "yesterday" names its own day (the 28th), so it keeps it; the others take the given date.
        #expect(requests.map(\.date) == [f.day("2026-10-27"), f.day("2026-10-28"), f.day("2026-10-27")])
        let entries = try f.journal.logAll(requests, actor: .mcp, origin: .agent)
        #expect(entries.map(\.day) == ["2026-10-27", "2026-10-28", "2026-10-27"])
        #expect(entries[2].occurredAt?.hasPrefix("2026-10-27T11:00") == true)
        // With no date and no day in the line, a line is for today.
        let today = f.journal.requests(fromTranscript: "- Fixed a bug", date: nil)
        #expect(today.map(\.date) == [nil])
        #expect(try f.journal.preview(today[0], origin: .agent).day == "2026-10-29")
    }

    @Test func anEmptyTranscriptHasNoRequests() throws {
        let f = try Fixture()
        #expect(f.journal.requests(fromTranscript: "\n \n-\nWed 28 Oct\n", date: nil).isEmpty)
    }

    // MARK: plan edits

    @Test func editingATaskChangesItsTitleTicketAndEstimate() throws {
        let f = try Fixture()
        let task = try f.journal.planAdd(title: "Draft the ADR", day: nil, estimateMin: 30, origin: .suggested, actor: .mcp)
        let edited = try f.journal.planEdit(
            taskID: task.id, title: "Draft the idempotency ADR ACME-482913", estimateMin: 90, actor: .mcp)
        #expect(edited.title == "Draft the idempotency ADR ACME-482913")
        #expect(edited.ticket == Ticket(key: "ACME-482913", class: .assigned))
        #expect(edited.estimateMin == 90)
        #expect(edited.origin == .suggested && edited.status == .open)
        let events = try f.journal.history(subject: "task:\(task.id)")
        #expect(events.map(\.type) == ["plan.added", "plan.updated"])
        #expect(events.last?.actor == .mcp)
        // Dropping the ticket from the title drops it from the task.
        let plain = try f.journal.planEdit(taskID: task.id, title: "Draft the ADR", estimateMin: nil, actor: .mcp)
        #expect(plain.ticket == nil && plain.estimateMin == 90)
    }

    @Test func aPlanEditThatChangesNothingWritesNothing() throws {
        let f = try Fixture()
        let task = try f.journal.planAdd(title: "Draft the ADR", day: nil, estimateMin: 30, origin: .suggested, actor: .mcp)
        let before = try f.store.eventCount()
        let same = try f.journal.planEdit(taskID: task.id, title: "Draft  the ADR", estimateMin: 30, actor: .mcp)
        #expect(same == task)
        #expect(try f.store.eventCount() == before)
    }

    @Test func aPlanEditIsRefusedForTheWrongInput() throws {
        let f = try Fixture()
        let task = try f.journal.planAdd(title: "Draft the ADR", day: nil, estimateMin: nil, origin: .suggested, actor: .mcp)
        #expect(throws: CadenceError.self) { try f.journal.planEdit(taskID: task.id, title: nil, estimateMin: nil, actor: .mcp) }
        #expect(throws: CadenceError.self) { try f.journal.planEdit(taskID: task.id, title: " ", estimateMin: nil, actor: .mcp) }
        #expect(throws: CadenceError.self) { try f.journal.planEdit(taskID: task.id, title: nil, estimateMin: 0, actor: .mcp) }
        #expect(throws: CadenceError.self) { try f.journal.planEdit(taskID: task.id, title: nil, estimateMin: 1441, actor: .mcp) }
        #expect(throws: CadenceError.notFound("no plan task with id nope")) {
            try f.journal.planEdit(taskID: "nope", title: "x", estimateMin: nil, actor: .mcp)
        }
        _ = try f.journal.planResolve(taskID: task.id, status: .done, reason: nil, note: nil, links: [], actor: .mcp)
        #expect(throws: CadenceError.self) { try f.journal.planEdit(taskID: task.id, title: "Changed", estimateMin: nil, actor: .mcp) }
        #expect(try f.journal.task(task.id).title == "Draft the ADR")
    }

    @Test func plannedEditsRebuildByteForByte() throws {
        let f = try Fixture()
        let task = try f.journal.planAdd(title: "Draft the ADR", day: nil, estimateMin: 30, origin: .suggested, actor: .mcp)
        _ = try f.journal.planEdit(taskID: task.id, title: "Draft the ADR ACME-100001", estimateMin: 45, actor: .mcp)
        let before = try f.journal.dayView(f.day("2026-10-29"))
        try f.store.rebuild()
        #expect(try f.journal.dayView(f.day("2026-10-29")) == before)
    }

    // MARK: stand-up without a witness

    @Test func standupTextIsTheStandupWithoutTheWitnessLineAndWritesNothing() throws {
        let f = try Fixture()
        _ = try f.journal.log(LogRequest(text: "Fixed the flaky ledger test ACME-482913"), actor: .cli, origin: .selfReported)
        let before = try f.store.eventCount()
        let text = try f.journal.standupText(nil)
        #expect(try f.store.eventCount() == before)
        #expect(text.hasPrefix("*Thu 29 Oct*\nDone\n"))
        #expect(text.hasSuffix("Blockers: none"))
        let full = try f.journal.standup(nil, actor: .cli)
        #expect(full.text == text + "\n" + "cadence " + full.code)
        #expect(throws: CadenceError.self) { try f.journal.standupText(f.day("2026-10-30")) }
    }

    // MARK: the ring

    @Test func theRingCountsPlannedTasksAndAcceptedEntries() throws {
        let f = try Fixture()
        let a = try f.journal.planAdd(title: "One", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        let b = try f.journal.planAdd(title: "Two", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try f.journal.planAdd(title: "Three", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try f.journal.planResolve(taskID: a.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        _ = try f.journal.planResolve(taskID: b.id, status: .slipped, reason: "blocked", note: nil, links: [], actor: .cli)
        _ = try f.journal.log(LogRequest(text: "Merged ACME-482913 retry budget"), actor: .cli, origin: .selfReported)
        _ = try f.journal.log(LogRequest(text: "Reviewed a design doc"), actor: .cli, origin: .selfReported)
        _ = try f.journal.log(LogRequest(text: "Reviewed another doc", proposed: true), actor: .mcp, origin: .agent)
        let ring = DayRing(try f.journal.dayView(f.day("2026-10-29")))
        #expect(ring.planned == 3 && ring.done == 1 && ring.slipped == 1 && ring.dropped == 0 && ring.open == 1)
        #expect(ring.beads == [DayRing.Bead(family: .delivery, count: 1), DayRing.Bead(family: .review, count: 1)])
        #expect(!ring.sealed && !ring.closed)
        #expect(ring.text == "Ring: 1 of 3 planned tasks done, 1 slipped, 1 open; delivery 1, review 1; not sealed")

        // Sealing carries the open task away, so the ring closes.
        _ = try f.journal.seal(f.day("2026-10-29"), actor: .cli)
        let sealed = DayRing(try f.journal.dayView(f.day("2026-10-29")))
        #expect(sealed.planned == 2 && sealed.open == 0 && sealed.closed)
        #expect(sealed.json["closed"] == .bool(true) && sealed.json["beads"]?["delivery"] == .int(1))
    }

    @Test func aQuietDayHasAnEmptyRing() throws {
        let f = try Fixture()
        let ring = DayRing(try f.journal.dayView(f.day("2026-10-29")))
        #expect(ring.planned == 0 && ring.beads.isEmpty)
        #expect(ring.text == "Ring: no planned tasks; not sealed")
    }
}
