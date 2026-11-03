import Foundation
import Testing

@testable import CadenceCore

@Suite("Event payload codecs")
struct EventPayloadTests {
    struct Golden {
        let type: String
        let subject: String
        let data: JSONValue
    }

    static func golden() throws -> [Golden] {
        guard case .array(let items) = try Vectors.json("payloads/golden.json") else { return [] }
        return items.map {
            Golden(
                type: $0["type"]?.stringValue ?? "", subject: $0["subject"]?.stringValue ?? "",
                data: $0["data"] ?? .null)
        }
    }

    static func entry(_ type: String) throws -> Golden {
        guard let g = try golden().first(where: { $0.type == type }) else {
            throw CadenceError.notFound("golden \(type)")
        }
        return g
    }

    @Test func goldenCoversEveryTypeOnce() throws {
        let types = try Self.golden().map(\.type)
        #expect(types == EventPayload.allTypes)
        #expect(Set(EventPayload.allTypes).count == EventPayload.allTypes.count)
        #expect(EventPayload.allTypes.count == 20)
    }

    @Test func goldenRoundTripsByteForByte() throws {
        for g in try Self.golden() {
            let payload = try EventPayload(type: g.type, data: g.data)
            #expect(payload.type == g.type)
            #expect(payload.data == g.data, "\(g.type)")
            #expect(try CanonicalJSON.bytes(payload.data) == CanonicalJSON.bytes(g.data), "\(g.type)")
        }
    }

    @Test func subjects() throws {
        for g in try Self.golden() {
            let payload = try EventPayload(type: g.type, data: g.data)
            let id = g.subject.split(separator: ":", maxSplits: 1).last.map(String.init)
            #expect(payload.subject(id: id) == g.subject, "\(g.type)")
            let draft = payload.draft(actor: .cli, id: id)
            #expect(draft.subject == g.subject)
            #expect(draft.type == g.type)
            #expect(draft.data == g.data)
            #expect(draft.actor == .cli)
        }
        let updated = try EventPayload(type: "plan.updated", data: Self.entry("plan.updated").data)
        #expect(updated.subject(id: nil) == nil)
        #expect(updated.subject(id: "T1") == "task:T1")
        let added = try EventPayload(type: "plan.added", data: Self.entry("plan.added").data)
        #expect(added.subject(id: nil) == "task:01JBX3K8Q2M4N5P6R7S8T9V0WA")
    }

    private func expectInvalid(_ type: String, _ data: JSONValue, mentions field: String) {
        do {
            _ = try EventPayload(type: type, data: data)
            Issue.record("\(type): expected a validation error for \(field)")
        } catch {
            guard case .validation(let message) = error else {
                Issue.record("\(type): wrong error \(error)")
                return
            }
            #expect(message.contains(field), "\(message) should name \(field)")
        }
    }

    private func mutated(_ type: String, _ change: (inout [String: JSONValue]) -> Void) throws -> JSONValue {
        var object = try Self.entry(type).data.objectValue ?? [:]
        change(&object)
        return .object(object)
    }

    @Test func rejectsUnknownType() {
        #expect(throws: CadenceError.self) { try EventPayload(type: "nope", data: [:]) }
    }

    @Test func rejectsExtraKey() throws {
        expectInvalid("day.started", try mutated("day.started") { $0["extra"] = 1 }, mentions: "extra")
        expectInvalid("entry.created", try mutated("entry.created") { $0["extra"] = 1 }, mentions: "extra")
    }

    @Test func rejectsMissingKey() throws {
        expectInvalid("day.started", try mutated("day.started") { $0["source"] = nil }, mentions: "source")
        expectInvalid("day.noted", try mutated("day.noted") { $0["on_call"] = nil }, mentions: "on_call")
        expectInvalid("entry.created", try mutated("entry.created") { $0["quantity"] = nil }, mentions: "quantity")
    }

    @Test func rejectsWrongType() throws {
        expectInvalid("day.started", try mutated("day.started") { $0["tz"] = 5 }, mentions: "tz")
        expectInvalid("day.noted", try mutated("day.noted") { $0["on_call"] = "yes" }, mentions: "on_call")
        expectInvalid("genai.usage", try mutated("genai.usage") { $0["sessions"] = "5" }, mentions: "sessions")
        expectInvalid("plan.committed", try mutated("plan.committed") { $0["tasks"] = "a" }, mentions: "tasks")
    }

    @Test func rejectsNegativeCounts() throws {
        var tokens = try Self.entry("genai.usage").data["tokens"]?.objectValue ?? [:]
        tokens["in"] = -1
        expectInvalid("genai.usage", try mutated("genai.usage") { $0["tokens"] = .object(tokens) }, mentions: "in")
        expectInvalid("genai.usage", try mutated("genai.usage") { $0["cost_micros"] = -5 }, mentions: "cost_micros")
        expectInvalid("ingest.run", try mutated("ingest.run") { $0["counts"] = ["created": -1] }, mentions: "counts")
    }

    @Test func rejectsUnknownEnumValues() throws {
        expectInvalid("day.started", try mutated("day.started") { $0["source"] = "telepathy" }, mentions: "source")
        expectInvalid("day.declared", try mutated("day.declared") { $0["kind"] = "vacation" }, mentions: "kind")
        expectInvalid("plan.resolved", try mutated("plan.resolved") { $0["status"] = "finished" }, mentions: "status")
        expectInvalid("entry.status", try mutated("entry.status") { $0["to"] = "archived" }, mentions: "to")
    }

    @Test func planAddedMustBeOpen() throws {
        expectInvalid("plan.added", try mutated("plan.added") { $0["status"] = "done" }, mentions: "status")
    }

    @Test func changesAreChecked() throws {
        expectInvalid(
            "plan.updated", try mutated("plan.updated") { $0["changes"] = ["status": ["open", "done"]] },
            mentions: "status")
        expectInvalid(
            "plan.updated", try mutated("plan.updated") { $0["changes"] = ["title": "x"] }, mentions: "title")
        expectInvalid(
            "entry.updated", try mutated("entry.updated") { $0["changes"] = ["title": ["a"]] }, mentions: "title")
        expectInvalid(
            "entry.updated", try mutated("entry.updated") { $0["changes"] = ["origin": ["self", "agent"]] },
            mentions: "origin")
    }

    @Test func dayReopenedCarriesTheDayAndNothingElse() throws {
        // No free text, no zone, no reason: the event says only which day was reopened.
        expectInvalid("day.reopened", try mutated("day.reopened") { $0["reason"] = "Forgot a review" }, mentions: "reason")
        expectInvalid("day.reopened", try mutated("day.reopened") { $0["tz"] = "UTC" }, mentions: "tz")
        expectInvalid("day.reopened", try mutated("day.reopened") { $0["day"] = nil }, mentions: "day")
        expectInvalid("day.reopened", try mutated("day.reopened") { $0["day"] = "2026-13-01" }, mentions: "day")
        expectInvalid("day.reopened", try mutated("day.reopened") { $0["day"] = 5 }, mentions: "day")
        let payload = try EventPayload(type: "day.reopened", data: Self.entry("day.reopened").data)
        #expect(payload.subject(id: nil) == "day:2026-10-29")
        #expect(payload.data == ["day": "2026-10-29"])
    }

    @Test func rejectsBadDatesAndTimes() throws {
        expectInvalid("day.started", try mutated("day.started") { $0["day"] = "2026-13-01" }, mentions: "day")
        expectInvalid("day.started", try mutated("day.started") { $0["at"] = "16:02" }, mentions: "at")
        expectInvalid("presence.span", try mutated("presence.span") { $0["end"] = "16:02" }, mentions: "end")
        expectInvalid("entry.created", try mutated("entry.created") { $0["day"] = "2026-13-01" }, mentions: "day")
        expectInvalid(
            "genai.session", try mutated("genai.session") { $0["started_at"] = "yesterday" },
            mentions: "started_at")
    }
}
