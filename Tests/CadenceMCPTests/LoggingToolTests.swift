import CadenceCore
import Foundation
import Testing

@testable import CadenceMCP

/// log_entry and log_entries (docs/SPEC.md section 9.2): origin agent, accepted for today, proposed otherwise.
@Suite struct LoggingToolTests {
    /// The entry.created events in the ledger, in order, and the entries they hold.
    func createdEvents(_ h: ToolHarness) throws -> [Event] { try h.events().filter { $0.type == "entry.created" } }

    func created(_ h: ToolHarness) throws -> [Entry] { try createdEvents(h).map { try Entry(json: $0.data) } }

    // MARK: log_entry

    @Test func aLineForTodayIsAcceptedAndMatchesTheSpecsResult() throws {
        let h = try ToolHarness()
        let reply = try h.call(
            "log_entry", ["text": "Fixed flaky ledger test with deterministic clock", "ticket": "ACME-482913"])
        #expect(!reply.isError && reply.result?["resultType"] == "complete")
        #expect(reply.text == "Logged for Thu 29 Oct: Fixed flaky ledger test with deterministic clock (ACME-482913).")
        let structured = try #require(reply.structured)
        #expect(structured["status"] == "accepted")
        let entry = try #require(structured["entry"])
        let id = try #require(entry["id"]?.stringValue)
        #expect(id.hasPrefix("01TEST"))
        #expect(entry == [
            "id": .string(id), "day": "2026-10-29", "kind": "work.done", "family": "delivery",
            "title": "Fixed flaky ledger test with deterministic clock", "ticket": ["key": "ACME-482913", "class": "assigned"],
            "origin": "agent",
        ])
    }

    @Test func theEventCarriesActorMcpAndOriginAgent() throws {
        let h = try ToolHarness()
        let reply = try h.call("log_entry", ["text": "Reviewed the settlement batching RFC"])
        let events = try createdEvents(h)
        #expect(events.count == 1)
        let event = try #require(events.first)
        let entry = try Entry(json: event.data)
        #expect(event.actor == .mcp)
        #expect(event.data["origin"] == "agent")
        #expect(entry.origin == .agent && entry.status == .accepted && !entry.backfilled)
        #expect(event.subject == "entry:" + (reply.structured?["entry"]?["id"]?.stringValue ?? ""))
        // The genesis event is the only other thing in the ledger.
        #expect(try h.events().map(\.type) == ["ledger.genesis", "entry.created"])
    }

    @Test func aPastDayIsProposedAndWaitsInTheInbox() throws {
        let h = try ToolHarness()
        let reply = try h.call("log_entry", ["text": "Paired on the capture path", "date": "2026-10-28"])
        #expect(!reply.isError)
        #expect(reply.structured?["status"] == "proposed")
        #expect(reply.text.hasPrefix("Proposed for Wed 28 Oct: Paired on the capture path."))
        #expect(reply.text.contains("only the user can accept it"))
        let entry = try #require(try created(h).first)
        #expect(entry.status == .proposed && entry.origin == .agent && entry.backfilled && entry.day == "2026-10-28")
        #expect(try h.journal().inbox().map(\.title) == ["Paired on the capture path"])
    }

    @Test func explicitFieldsOverrideTheParse() throws {
        let h = try ToolHarness()
        let reply = try h.call(
            "log_entry",
            [
                "text": "Looked at ACME-100001 yesterday for 5m", "kind": "review.given", "date": "2026-10-29", "occurred_at": "09:15",
                "ticket": "ACME-000000", "duration_min": 90, "quantity": 3, "note": "paired with a teammate",
                "links": [["url": "https://git.example.com/acme/core/pull/7", "kind": "pr"], ["url": "https://docs.example.com/browse/ACME-9"]],
            ])
        #expect(!reply.isError)
        let entry = try #require(try created(h).first)
        #expect(entry.kind == .reviewGiven && entry.family == .review && entry.day == "2026-10-29")
        #expect(entry.occurredAt?.hasPrefix("2026-10-29T09:15") == true)
        #expect(entry.ticket == Ticket(key: "ACME-000000", class: .selfInitiated))
        #expect(entry.durationS == 5400 && entry.quantity == 3 && entry.attrs["note"] == "paired with a teammate")
        #expect(entry.links == [
            Link(kind: .pr, url: "https://git.example.com/acme/core/pull/7"),
            Link(kind: .ticket, url: "https://docs.example.com/browse/ACME-9"),
        ])
    }

    @Test func aRefusalIsAReadableToolErrorAndWritesNothing() throws {
        let h = try ToolHarness()
        _ = try h.call("log_entry", ["text": "Fixed a bug"])
        let before = try h.eventCount()
        let long = String(repeating: "x", count: 501)
        let cases: [(JSONValue, String)] = [
            (["text": "   "], "Not done: text must not be empty"),
            (["text": "Fixed it", "date": "2026-10-30"], "Not done: date: 2026-10-30 is in the future"),
            (["text": "Fixed it", "occurred_at": "23:30"], "Not done: occurred_at: 23:30 is in the future"),
            (["text": "Fixed it", "ticket": "no key here"], "Not done: ticket: no ticket key found"),
            (["text": "Fixed it", "links": [["url": "http://example.com/x"]]], "Not done: link: only https links are accepted"),
            (["text": "Fixed it", "kind": "work.finished"], "Not done: kind: 'work.finished' is not valid; use one of "),
            (["text": "Fixed it", "kind": "genai.session"], "Not done: kind: 'genai.session' is not valid; use one of "),
            (["text": "Fixed it", "kind": "presence.span"], "Not done: kind: 'presence.span' is not valid; use one of "),
            (["text": .string(long)], "Not done: text: must be at most 500 characters."),
            (["text": "Fixed it", "duration_min": 0], "Not done: duration_min: must be at least 1."),
            (["text": "Fixed it", "quantity": 51], "Not done: quantity: must be at most 50."),
            (["text": "Fixed it", "date": "29/10/2026"], "Not done: date: must be a date as YYYY-MM-DD."),
            (["text": "Fixed it", "origin": "self"], "Not done: origin: is not a known argument."),
            (["text": "Fixed it", "status": "accepted"], "Not done: status: is not a known argument."),
            ([:], "Not done: text: is required."),
        ]
        for (arguments, expected) in cases {
            let reply = try h.call("log_entry", arguments)
            #expect(reply.rpcError == nil, "\(arguments)")
            #expect(reply.isError, "\(arguments)")
            #expect(reply.text.hasPrefix(expected), "\(arguments) gave \(reply.text)")
        }
        // The kinds offered back leave out the ones only the machine side records.
        let offered = try h.call("log_entry", ["text": "Fixed it", "kind": "nope"]).text.components(separatedBy: "use one of ")[1]
        #expect(offered.contains("work.done") && offered.contains("review.given"))
        #expect(!offered.contains("genai") && !offered.contains("presence.span"))
        #expect(try h.eventCount() == before)
    }

    @Test func aBusyOrFailingStoreIsAToolErrorToo() throws {
        let h = try ToolHarness(failWith: .storeBusy)
        let reply = try h.call("log_entry", ["text": "Fixed a bug"])
        #expect(reply.rpcError == nil && reply.isError)
        #expect(reply.text == "Not done: the store is busy; another Cadence process is writing. Try again.")
        let read = try h.call("get_day")
        #expect(read.rpcError == nil && read.isError)
    }

    // MARK: rate limit

    @Test func sixtyWritesAMinuteThenTheLimit() throws {
        let h = try ToolHarness()
        for n in 0..<60 {
            let reply = try h.call("log_entry", ["text": .string("Fixed bug number \(n)")])
            #expect(reply.result != nil && !reply.isError, "call \(n)")
        }
        let refused = try h.call("log_entry", ["text": "One too many"])
        #expect(refused.rpcError?["code"] == .int(RPCError.rateLimited))
        #expect(try created(h).count == 60)
        // Reads are not limited, and the window slides.
        #expect(try h.call("get_day").result != nil)
        #expect(try h.call("plan_add", ["tasks": [["title": "Plan it"]]]).rpcError?["code"] == .int(RPCError.rateLimited))
        h.clock.advance(by: 61)
        #expect(try h.call("log_entry", ["text": "Fixed it later"]).result != nil)
    }

    // MARK: log_entries

    static let transcript = """
        Wed 28 Oct
        - Reviewed settlement batching RFC ACME-482913
        • Paired on the flaky ledger test ~1h
        - Raised retry storms in arch sync @10:30
        """

    @Test func dryRunIsTheDefaultAndRecordsNothing() throws {
        let h = try ToolHarness()
        let before = try h.eventCount()
        for arguments: JSONValue in [["transcript": .string(Self.transcript)], ["transcript": .string(Self.transcript), "dry_run": true]] {
            let reply = try h.call("log_entries", arguments)
            #expect(!reply.isError)
            #expect(reply.structured?["status"] == "preview" && reply.structured?["dry_run"] == true)
            #expect(reply.structured?["recorded"] == 0 && reply.structured?["problems"] == 0)
            #expect(reply.text.hasPrefix("Preview: 3 entries for the Inbox. Nothing is recorded yet."))
            #expect(reply.text.contains("2026-10-28") && reply.text.contains("10:30") && reply.text.contains("Paired on the flaky ledger test"))
            #expect(reply.text.contains("call log_entries again with the same input and dry_run false"))
            let rows = try #require(reply.structured?["entries"]?.arrayValue)
            #expect(rows.map { $0["line"] } == [1, 2, 3])
            #expect(rows.map { $0["status"] } == ["proposed", "proposed", "proposed"])
            #expect(rows.allSatisfy { $0["id"] == nil && $0["origin"] == "agent" })
        }
        #expect(try h.eventCount() == before)
    }

    @Test func aRealRunLandsEveryLineInTheInboxAsAProposalMarkedDictated() throws {
        let h = try ToolHarness()
        let preview = try h.call("log_entries", ["transcript": .string(Self.transcript)])
        let real = try h.call("log_entries", ["transcript": .string(Self.transcript), "dry_run": false])
        #expect(!real.isError)
        #expect(real.structured?["status"] == "proposed" && real.structured?["recorded"] == 3)
        #expect(real.text.hasPrefix("Put 3 entries in the user's Inbox as proposals."))
        let events = try createdEvents(h)
        let written = try created(h)
        #expect(written.count == 3)
        #expect(events.allSatisfy { $0.actor == .mcp })
        for entry in written {
            #expect(entry.origin == .agent && entry.status == .proposed)
            #expect(entry.attrs["dictated"] == true && entry.day == "2026-10-28" && entry.backfilled)
            #expect(real.text.contains(entry.id))
        }
        // What the preview showed is what landed.
        let shown = try #require(preview.structured?["entries"]?.arrayValue)
        #expect(shown.compactMap { $0["title"]?.stringValue } == written.map(\.title))
        #expect(shown.compactMap { $0["kind"]?.stringValue } == written.map(\.kind.rawValue))
        #expect(try h.journal().inbox().count == 3)
        #expect(try h.events().filter { $0.type == "entry.status" }.isEmpty)
    }

    @Test func todaysLinesFromLogEntriesAreProposedToo() throws {
        let h = try ToolHarness()
        let reply = try h.call("log_entries", ["transcript": "- Fixed a flaky test\n- Reviewed a design doc", "dry_run": false])
        #expect(!reply.isError)
        let entries = try created(h)
        #expect(entries.map(\.day) == ["2026-10-29", "2026-10-29"])
        #expect(entries.allSatisfy { $0.status == .proposed && !$0.backfilled })
    }

    @Test func theDateArgumentIsForLinesThatNameNoDay() throws {
        let h = try ToolHarness()
        let transcript = "- Reviewed a design doc\n- Fixed a test yesterday\n- Led a retro at 11:00"
        _ = try h.call("log_entries", ["transcript": .string(transcript), "date": "2026-10-27", "dry_run": false])
        #expect(try created(h).map(\.day) == ["2026-10-27", "2026-10-28", "2026-10-27"])
    }

    @Test func aListOfEntriesTakesTheSameFieldsAsLogEntry() throws {
        let h = try ToolHarness()
        let reply = try h.call(
            "log_entries",
            [
                "entries": [
                    ["text": "Reviewed a design doc", "kind": "doc.reviewed", "occurred_at": "10:00"],
                    ["text": "Fixed the retry budget", "ticket": "ACME-482913", "date": "2026-10-27", "duration_min": 30],
                ],
                "date": "2026-10-28", "dry_run": false,
            ])
        #expect(!reply.isError)
        let entries = try created(h)
        #expect(entries.map(\.day) == ["2026-10-28", "2026-10-27"])
        #expect(entries.map(\.kind) == [.docReviewed, .workDone])
        #expect(entries[1].ticket?.key == "ACME-482913" && entries[1].durationS == 1800)
        #expect(entries.allSatisfy { $0.origin == .agent && $0.status == .proposed && $0.attrs["dictated"] == nil })
    }

    @Test func aBadLineIsShownInThePreviewAndRefusesTheWholeRealRun() throws {
        let h = try ToolHarness()
        let entries: JSONValue = [
            ["text": "Reviewed a design doc"], ["text": "From the future", "date": "2026-11-02"], ["text": "Fixed a test", "kind": "genai.usage"],
        ]
        let preview = try h.call("log_entries", ["entries": entries])
        #expect(!preview.isError && preview.structured?["problems"] == 2 && preview.structured?["status"] == "preview")
        #expect(preview.text.hasPrefix("Preview: 3 lines, 2 cannot be recorded. Nothing is recorded yet."))
        #expect(preview.text.contains("not recorded: date: 2026-11-02 is in the future"))
        let rows = try #require(preview.structured?["entries"]?.arrayValue)
        #expect(rows[1]["problem"] == "date: 2026-11-02 is in the future" && rows[0]["problem"] == nil)

        let before = try h.eventCount()
        let real = try h.call("log_entries", ["entries": entries, "dry_run": false])
        #expect(real.isError && real.rpcError == nil)
        #expect(real.text.hasPrefix("Not done: nothing was recorded, because 2 of 3 lines cannot be: line 2: date: 2026-11-02 is in the future; line 3: kind: 'genai.usage'"))
        #expect(try h.eventCount() == before)
    }

    @Test func logEntriesRefusesTheWrongShapesOfInput() throws {
        let h = try ToolHarness()
        let many = (0..<26).map { JSONValue.object(["text": .string("Fixed bug \($0)")]) }
        let cases: [(JSONValue, String)] = [
            ([:], "Not done: give a transcript or a list of entries"),
            (["transcript": "- Fixed it", "entries": [["text": "Fixed it"]]], "Not done: give either transcript or entries, not both"),
            (["transcript": "\n \n-\nWed 28 Oct\n"], "Not done: there is nothing to record: the transcript has no lines"),
            (["entries": []], "Not done: entries: give at least one entry"),
            (["entries": .array(many)], "Not done: entries: at most 25 items."),
            (["transcript": .string((1...26).map { "- Fixed bug \($0)" }.joined(separator: "\n"))], "Not done: 26 entries is more than 25 in one call; send them in batches"),
            (["entries": [["text": "Fixed it", "date": "nope"]]], "Not done: entries[0].date: must be a date as YYYY-MM-DD."),
            (["entries": [["text": "Fixed it", "kind": "x.y"]], "dry_run": false], "Not done: nothing was recorded, because 1 of 1 lines cannot be: line 1: kind: 'x.y' is not valid"),
            (["transcript": "- Fixed it", "dry_run": "no"], "Not done: dry_run: must be true or false."),
            (["transcript": "- Fixed it", "status": "accepted"], "Not done: status: is not a known argument."),
        ]
        for (arguments, expected) in cases {
            let reply = try h.call("log_entries", arguments)
            #expect(reply.isError && reply.rpcError == nil, "\(arguments)")
            #expect(reply.text.hasPrefix(expected), "\(arguments) gave \(reply.text)")
        }
        #expect(try created(h).isEmpty)
    }

    @Test func aFullBatchOfLongTitlesStillFitsTheResultLimit() throws {
        let h = try ToolHarness()
        let title = String(repeating: "retry budget rollout ", count: 12).trimmingCharacters(in: .whitespaces)
        let entries = (0..<CadenceMCP.maxBatch).map { JSONValue.object(["text": .string("Fixed \(title) \($0)"), "ticket": "ACME-482913"]) }
        let preview = try h.call("log_entries", ["entries": .array(entries)])
        #expect(!preview.isError && preview.size < MCPServer.maxResultCharacters)
        #expect(!preview.text.contains("cut at"))
        let real = try h.call("log_entries", ["entries": .array(entries), "dry_run": false])
        #expect(!real.isError && real.size < MCPServer.maxResultCharacters && !real.text.contains("cut at"))
        #expect(try created(h).count == CadenceMCP.maxBatch)
    }
}
