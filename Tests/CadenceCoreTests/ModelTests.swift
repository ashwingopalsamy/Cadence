import Foundation
import Testing

@testable import CadenceCore

@Suite struct ModelTests {
    // MARK: enums

    @Test func enumRawValuesMatchTheSpec() {
        #expect(Origin.allCases.map(\.rawValue) == ["observed", "collected", "agent", "self"])
        #expect(EntryStatus.allCases.map(\.rawValue) == ["proposed", "accepted", "dismissed", "deleted"])
        #expect(
            DayKind.allCases.map(\.rawValue)
                == ["workday", "weekend", "holiday", "leave_planned", "leave_unplanned"])
        #expect(PlanOrigin.allCases.map(\.rawValue) == ["self", "suggested", "carried"])
        #expect(TaskStatus.allCases.map(\.rawValue) == ["open", "done", "slipped", "dropped", "moved"])
        #expect(TicketClass.allCases.map(\.rawValue) == ["assigned", "self"])
        #expect(ExportPolicy.allCases.map(\.rawValue) == ["include", "digest", "exclude"])
        #expect(PresenceSource.allCases.map(\.rawValue) == ["input", "wake", "unlock", "powerlog", "manual"])
        #expect(LinkKind.allCases.map(\.rawValue) == ["pr", "ticket", "doc", "other"])
        #expect(
            Family.allCases.map(\.rawValue)
                == ["delivery", "review", "initiative", "ownership", "leadership", "ai", "presence"])
        #expect(Weekday.allCases.map(\.rawValue) == ["mon", "tue", "wed", "thu", "fri", "sat", "sun"])
        #expect(
            EntryKind.allCases.map(\.rawValue) == [
                "pr.opened", "pr.merged", "shipped", "work.done", "review.given", "doc.reviewed",
                "initiative.started", "initiative.progress", "incident.handled", "oncall.shift",
                "discussion.raised", "decision.challenged", "meeting.led", "mentoring", "doc.written",
                "genai.session", "genai.usage", "presence.span", "meeting.attended", "note",
            ])
    }

    @Test func ringOrderExcludesPresence() {
        #expect(Family.ringOrder == [.delivery, .review, .initiative, .ownership, .leadership, .ai])
    }

    @Test func computedFlags() {
        #expect(DayKind.allCases.filter(\.isLeaveOrHoliday) == [.holiday, .leavePlanned, .leaveUnplanned])
        #expect(TaskStatus.allCases.filter(\.isResolved) == [.done, .slipped, .dropped])
    }

    @Test func enumsAreCodable() throws {
        let data = try JSONEncoder().encode([EntryKind.prMerged, .note])
        #expect(String(decoding: data, as: UTF8.self) == "[\"pr.merged\",\"note\"]")
        #expect(try JSONDecoder().decode([Origin].self, from: Data("[\"self\"]".utf8)) == [.selfReported])
    }

    @Test func defaultFamilyForEveryKind() {
        let expected: [EntryKind: Family] = [
            .prOpened: .delivery, .prMerged: .delivery, .shipped: .delivery, .workDone: .delivery,
            .reviewGiven: .review, .docReviewed: .review,
            .initiativeStarted: .initiative, .initiativeProgress: .initiative,
            .incidentHandled: .ownership, .oncallShift: .ownership,
            .discussionRaised: .leadership, .decisionChallenged: .leadership, .meetingLed: .leadership,
            .mentoring: .leadership, .docWritten: .leadership,
            .genaiSession: .ai, .genaiUsage: .ai,
            .presenceSpan: .presence, .meetingAttended: .presence, .note: .presence,
        ]
        #expect(expected.count == EntryKind.allCases.count)
        for kind in EntryKind.allCases {
            #expect(kind.defaultFamily == expected[kind], "\(kind)")
        }
    }

    @Test func selfInitiatedTicketMovesDeliveryToInitiative() {
        #expect(EntryKind.family(for: .prMerged, ticketClass: .selfInitiated) == .initiative)
        #expect(EntryKind.family(for: .prOpened, ticketClass: .selfInitiated) == .initiative)
        #expect(EntryKind.family(for: .workDone, ticketClass: .selfInitiated) == .initiative)
        #expect(EntryKind.family(for: .prMerged, ticketClass: .assigned) == .delivery)
        #expect(EntryKind.family(for: .prMerged, ticketClass: nil) == .delivery)
        #expect(EntryKind.family(for: .reviewGiven, ticketClass: .selfInitiated) == .review)
        #expect(EntryKind.family(for: .genaiSession, ticketClass: .selfInitiated) == .ai)
    }

    // MARK: entry

    private var specExample: JSONValue {
        [
            "id": "01JBX7Q3K4Z8D2N6V0R5T9W1YE",
            "day": "2026-10-29",
            "kind": "pr.merged",
            "family": "delivery",
            "title": "Ship retry budget for capture path",
            "occurred_at": "2026-10-29T16:02:11+05:30",
            "ticket": ["key": "ACME-482913", "class": "assigned"],
            "links": [["kind": "pr", "url": "https://git.example.com/acme/ledger-core/pull/412"]],
            "attrs": [
                "repo": "acme/ledger-core", "number": 412, "additions": 184, "deletions": 37,
                "ai_assisted": true,
            ],
            "origin": "collected",
            "source": "github",
            "source_ref": "github:PR_kwDOAbc123:merged",
            "status": "accepted",
            "backfilled": false,
            "after_seal": false,
        ]
    }

    private var fullEntry: Entry {
        Entry(
            id: "01JBX7Q3K4Z8D2N6V0R5T9W1YE", day: "2026-10-29", kind: .prMerged, family: .delivery,
            title: "Ship retry budget for capture path", occurredAt: "2026-10-29T16:02:11+05:30",
            durationS: 1800, quantity: 2, ticket: Ticket(key: "ACME-482913", class: .assigned),
            links: [Link(kind: .pr, url: "https://git.example.com/acme/ledger-core/pull/412")],
            tags: ["retry", "capture"], attrs: ["number": 412, "ai_assisted": true, "repo": "acme/x"],
            origin: .collected, source: "github", sourceRef: "github:PR_kwDOAbc123:merged",
            status: .proposed, backfilled: true, afterSeal: true, export: .digest)
    }

    private var minimalEntry: Entry {
        Entry(id: "01JBX7Q3K4Z8D2N6V0R5T9W1YF", day: "2026-10-29", kind: .note, family: .presence,
              title: "Thought", origin: .selfReported)
    }

    @Test func entryRoundTrips() throws {
        #expect(try Entry(json: fullEntry.json) == fullEntry)
        #expect(try Entry(json: minimalEntry.json) == minimalEntry)
    }

    @Test func entryJSONHasAFixedShape() {
        let object = minimalEntry.json.objectValue ?? [:]
        #expect(
            Set(object.keys) == [
                "id", "day", "kind", "family", "title", "occurred_at", "duration_s", "quantity", "ticket",
                "links", "tags", "attrs", "origin", "source", "source_ref", "status", "backfilled",
                "after_seal", "export",
            ])
        #expect(object["occurred_at"] == .null)
        #expect(object["ticket"] == .null)
        #expect(object["origin"] == "self")
    }

    @Test func specExampleDecodes() throws {
        let entry = try Entry(json: specExample)
        #expect(entry.id == "01JBX7Q3K4Z8D2N6V0R5T9W1YE")
        #expect(entry.kind == .prMerged)
        #expect(entry.family == .delivery)
        #expect(entry.ticket == Ticket(key: "ACME-482913", class: .assigned))
        #expect(entry.links == [Link(kind: .pr, url: "https://git.example.com/acme/ledger-core/pull/412")])
        #expect(entry.attrs["number"] == 412)
        #expect(entry.attrs["ai_assisted"] == true)
        #expect(entry.origin == .collected)
        #expect(entry.sourceRef == "github:PR_kwDOAbc123:merged")
        #expect(entry.durationS == nil)
        #expect(entry.quantity == 1)
        #expect(entry.tags.isEmpty)
        #expect(entry.export == .include)
        #expect(entry.status == .accepted)
        #expect(!entry.backfilled && !entry.afterSeal)
    }

    @Test func missingTitleIsAValidationError() {
        var object = specExample.objectValue ?? [:]
        object["title"] = nil
        expectValidation(Entry.self, .object(object), mentioning: "title")
    }

    @Test func unknownEnumStringIsAValidationError() {
        var object = specExample.objectValue ?? [:]
        object["kind"] = "pr.exploded"
        expectValidation(Entry.self, .object(object), mentioning: "kind")
        object["kind"] = "pr.merged"
        object["origin"] = "robot"
        expectValidation(Entry.self, .object(object), mentioning: "origin")
        object["origin"] = "agent"
        object["ticket"] = ["key": "ACME-1", "class": "mine"]
        expectValidation(Entry.self, .object(object), mentioning: "class")
    }

    @Test func wrongTypesAreValidationErrors() {
        var object = specExample.objectValue ?? [:]
        object["title"] = 5
        expectValidation(Entry.self, .object(object), mentioning: "title")
        object["title"] = "ok"
        object["backfilled"] = "no"
        expectValidation(Entry.self, .object(object), mentioning: "backfilled")
        expectValidation(Entry.self, "nope", mentioning: "entry")
    }

    // MARK: plan task

    private var fullTask: PlanTask {
        PlanTask(
            id: "01JBX7Q3K4Z8D2N6V0R5T9W1Y0", day: "2026-10-29", position: 2, title: "Review retry budget doc",
            ticket: Ticket(key: "ACME-7", class: .selfInitiated), estimateMin: 45, origin: .carried,
            carriedFrom: "01JBX7Q3K4Z8D2N6V0R5T9W1Y1", status: .slipped, reason: "blocked",
            reasonNote: "waiting on review", linkedEntries: ["01JBX7Q3K4Z8D2N6V0R5T9W1YE"],
            plannedAt: "2026-10-29T04:10:00.000Z", resolvedAt: "2026-10-29T18:00:00.000Z")
    }

    private var minimalTask: PlanTask {
        PlanTask(id: "01JBX7Q3K4Z8D2N6V0R5T9W1Y2", day: "2026-10-29", position: 0, title: "Plan",
                 origin: .selfReported, plannedAt: "2026-10-29T04:10:00.000Z")
    }

    @Test func planTaskRoundTrips() throws {
        #expect(try PlanTask(json: fullTask.json) == fullTask)
        #expect(try PlanTask(json: minimalTask.json) == minimalTask)
        let keys = Set(fullTask.json.objectValue?.keys.map { $0 } ?? [])
        #expect(
            keys == [
                "id", "day", "position", "title", "ticket", "estimate_min", "origin", "carried_from",
                "status", "reason", "reason_note", "linked_entries", "planned_at", "resolved_at",
            ])
    }

    @Test func planTaskValidation() throws {
        var object = fullTask.json.objectValue ?? [:]
        object["title"] = nil
        expectValidation(PlanTask.self, .object(object), mentioning: "title")
        object["title"] = "x"
        object["status"] = "paused"
        expectValidation(PlanTask.self, .object(object), mentioning: "status")
        object["status"] = "open"
        object["origin"] = "other"
        expectValidation(PlanTask.self, .object(object), mentioning: "origin")
        var sparse = minimalTask.json.objectValue ?? [:]
        sparse["status"] = nil
        sparse["linked_entries"] = nil
        let decoded = try PlanTask(json: .object(sparse))
        #expect(decoded.status == .open)
        #expect(decoded.linkedEntries.isEmpty)
    }

    // MARK: day

    private var fullDay: Day {
        Day(date: "2026-10-29", tz: "Asia/Kolkata", kind: .leavePlanned, label: "Diwali",
            firstActivity: "2026-10-29T09:40:00+05:30", lastActivity: "2026-10-29T18:10:00+05:30",
            focus: "Retry budget", note: "Quiet day", onCall: true,
            sealedAt: "2026-10-30T04:01:00.000Z", sealEvent: "01JBX7Q3K4Z8D2N6V0R5T9W1Y3")
    }

    @Test func dayRoundTrips() throws {
        let minimal = Day(date: "2026-10-30", tz: "UTC")
        #expect(try Day(json: fullDay.json) == fullDay)
        #expect(try Day(json: minimal.json) == minimal)
        let keys = Set(minimal.json.objectValue?.keys.map { $0 } ?? [])
        #expect(
            keys == [
                "date", "tz", "kind", "label", "first_activity", "last_activity", "focus", "note",
                "on_call", "sealed_at", "seal_event",
            ])
    }

    @Test func dayValidation() {
        var object = fullDay.json.objectValue ?? [:]
        object["tz"] = nil
        expectValidation(Day.self, .object(object), mentioning: "tz")
        object["tz"] = "UTC"
        object["kind"] = "sabbatical"
        expectValidation(Day.self, .object(object), mentioning: "kind")
    }

    // MARK: helper

    private func expectValidation<T: JSONRepresentable>(
        _ type: T.Type, _ json: JSONValue, mentioning field: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do throws(CadenceError) {
            _ = try T(json: json)
            Issue.record("expected a validation error", sourceLocation: sourceLocation)
        } catch {
            guard case .validation(let message) = error else {
                Issue.record("expected .validation, got \(error)", sourceLocation: sourceLocation)
                return
            }
            #expect(message.contains(field), "\(message)", sourceLocation: sourceLocation)
        }
    }
}
