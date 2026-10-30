import CadenceCore
import Foundation
import Testing

@testable import CadenceMCP

/// get_day, query, summary and standup (docs/SPEC.md section 9.2): reads, which write nothing.
@Suite struct ReadToolTests {
    /// Entries written the way the CLI does, so they are the user's and accepted.
    @discardableResult
    func seed(_ h: ToolHarness, _ lines: [String]) throws -> [Entry] {
        try h.journal().logAll(lines.map { LogRequest(text: $0) }, actor: .cli, origin: .selfReported)
    }

    // MARK: get_day

    @Test func aDayShowsItsPlanEntriesPresenceAndRing() throws {
        let h = try ToolHarness()
        let journal = try h.journal()
        let task = try journal.planAdd(title: "Draft the ADR", day: nil, estimateMin: 60, origin: .selfReported, actor: .cli)
        _ = try journal.planAdd(title: "Review ACME-482913", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try journal.planResolve(taskID: task.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        try seed(h, ["Merged ACME-482913 retry budget at 10:30", "Reviewed a design doc"])
        _ = try h.call("log_entry", ["text": "Fixed a flaky test"])
        _ = try h.call("log_entry", ["text": "Reviewed another doc", "date": "2026-10-29", "kind": "doc.reviewed"])
        let before = try h.eventCount()

        let reply = try h.call("get_day")
        #expect(!reply.isError)
        let structured = try #require(reply.structured)
        #expect(structured["day"]?["date"] == "2026-10-29" && structured["day"]?["kind"] == "workday")
        #expect(structured["tasks"]?.arrayValue?.map { $0["title"] } == ["Draft the ADR", "Review ACME-482913"])
        #expect(structured["entries_total"] == 4 && structured["entries"]?.arrayValue?.count == 4)
        #expect(structured["presence"] == .array([]))
        #expect(structured["ring"]?["planned"] == 2 && structured["ring"]?["done"] == 1 && structured["ring"]?["open"] == 1)
        #expect(structured["ring"]?["closed"] == false && structured["ring"]?["sealed"] == false)
        #expect(structured["ring"]?["beads"]?["delivery"] == 2)
        #expect(reply.text.contains("Plan: 1 of 2 done"))
        #expect(reply.text.contains("Entries: 4"))
        #expect(reply.text.hasSuffix("Ring: 1 of 2 planned tasks done, 1 open; delivery 2, review 2; not sealed"))
        #expect(try h.eventCount() == before)
    }

    @Test func proposedEntriesShowAsProposedAndAreNotBeads() throws {
        let h = try ToolHarness()
        _ = try h.call("log_entry", ["text": "Paired on the capture path", "date": "2026-10-28"])
        let reply = try h.call("get_day", ["date": "2026-10-28"])
        #expect(reply.structured?["entries"]?.arrayValue?.map { $0["status"] } == ["proposed"])
        #expect(reply.structured?["ring"]?["beads"] == .object([:]))
        #expect(reply.text.contains("(proposed)"))
    }

    @Test func aQuietDayHasNoInventedValues() throws {
        let h = try ToolHarness()
        let reply = try h.call("get_day", ["date": "2026-10-27"])
        #expect(!reply.isError)
        #expect(reply.text.contains("No plan") && reply.text.contains("No entries"))
        #expect(reply.text.contains("First activity -, last activity -"))
        #expect(reply.structured?["day"]?["first_activity"] == .null)
        #expect(reply.structured?["ring"]?["planned"] == 0)
        #expect(try h.call("get_day", ["date": "2026-10-31"]).isError == false)  // a future day can hold a plan
    }

    @Test func getDayRefusesABadDate() throws {
        let h = try ToolHarness()
        let reply = try h.call("get_day", ["date": "yesterday"])
        #expect(reply.isError && reply.text == "Not done: date: must be a date as YYYY-MM-DD.")
    }

    @Test func aBusyDayIsCutToFitAndSaysSo() throws {
        let h = try ToolHarness()
        let title = String(repeating: "retry budget ", count: 14)
        try seed(h, (0..<150).map { "Fixed \(title) number \($0)" })
        let reply = try h.call("get_day")
        #expect(!reply.isError && reply.size < MCPServer.maxResultCharacters)
        let shown = try #require(reply.structured?["entries"]?.arrayValue?.count)
        #expect(shown < 150 && reply.structured?["entries_total"] == 150)
        #expect(reply.text.contains("Showing \(shown) of 150 entries; use query for this date to page through the rest."))
        #expect(reply.text.hasSuffix("not sealed"))
    }

    // MARK: query

    @Test func queryFiltersByRangeKindFamilyOriginAndStatus() throws {
        let h = try ToolHarness()
        try seed(h, ["Merged ACME-482913 retry budget", "Reviewed a design doc", "Raised retry storms in arch sync"])
        _ = try h.call("log_entry", ["text": "Paired on a fix", "date": "2026-10-28"])
        _ = try h.call("log_entry", ["text": "Wrote an ADR"])

        let all = try h.call("query", ["from": "2026-10-28"])
        #expect(!all.isError && all.structured?["count"] == 5 && all.structured?["next_cursor"] == .null)
        #expect(all.text.hasPrefix("Entries from 2026-10-28 to 2026-10-29: 5 on this page.\nDAY"))
        // Days in order, the proposed entry first.
        #expect(all.structured?["entries"]?.arrayValue?.first?["status"] == "proposed")

        func titles(_ arguments: JSONValue) throws -> [String] {
            let reply = try h.call("query", arguments)
            #expect(!reply.isError, "\(arguments): \(reply.text)")
            return (reply.structured?["entries"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }
        }
        #expect(try titles(["from": "2026-10-28", "origins": ["agent"]]) == ["Paired on a fix", "Wrote an ADR"])
        #expect(try titles(["from": "2026-10-28", "origins": ["self"], "families": ["review"]]) == ["Reviewed a design doc"])
        #expect(try titles(["kinds": ["pr.merged", "discussion.raised"]]).count == 2)
        #expect(try titles(["from": "2026-10-28", "statuses": ["proposed"]]) == ["Paired on a fix"])
        #expect(try titles(["from": "2026-10-28", "to": "2026-10-28"]) == ["Paired on a fix"])
        #expect(try titles(["statuses": ["dismissed"]]).isEmpty)
        #expect(try titles(["to": "2026-10-27"]).isEmpty)
        let none = try h.call("query", ["to": "2026-10-27"])
        #expect(none.text == "No entries from 2026-10-27 to 2026-10-27.")
        // No dates means today.
        #expect(try titles([:]).count == 4)
    }

    @Test func queryPagesWithACursorThatRoundTrips() throws {
        let h = try ToolHarness()
        try seed(h, (1...7).map { "Fixed bug number \($0)" })
        var seen: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            var arguments: [String: JSONValue] = ["limit": 3]
            if let cursor { arguments["cursor"] = .string(cursor) }
            let reply = try h.call("query", .object(arguments))
            #expect(!reply.isError)
            seen += (reply.structured?["entries"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }
            cursor = reply.structured?["next_cursor"]?.stringValue
            if let cursor { #expect(reply.text.hasSuffix("More entries: call query again with cursor \(cursor).")) }
            pages += 1
        } while cursor != nil && pages < 10
        #expect(pages == 3)
        #expect(seen == (1...7).map { "Fixed bug number \($0)" })
        // An entry written between pages does not shift the page already read.
        let first = try h.call("query", ["limit": 2])
        let cursorAfterTwo = try #require(first.structured?["next_cursor"]?.stringValue)
        _ = try h.call("log_entry", ["text": "Fixed a late bug"])
        let next = try h.call("query", ["limit": 2, "cursor": .string(cursorAfterTwo)])
        #expect(next.structured?["entries"]?.arrayValue?.compactMap { $0["title"]?.stringValue } == ["Fixed bug number 3", "Fixed bug number 4"])
    }

    @Test func aFullPageOf200StaysUnderTheLimitAndPagingCoversEveryEntry() throws {
        let h = try ToolHarness()
        let title = String(repeating: "retry budget ", count: 8)
        let written = try seed(h, (0..<230).map { "Fixed \(title) number \($0)" })
        var ids: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            var arguments: [String: JSONValue] = [:]
            if let cursor { arguments["cursor"] = .string(cursor) }
            let reply = try h.call("query", .object(arguments))
            #expect(!reply.isError && reply.size < MCPServer.maxResultCharacters, "page \(pages)")
            #expect(!reply.text.contains("cut at"))
            let page = reply.structured?["entries"]?.arrayValue ?? []
            #expect(!page.isEmpty && page.count <= 200)
            ids += page.compactMap { $0["id"]?.stringValue }
            cursor = reply.structured?["next_cursor"]?.stringValue
            pages += 1
        } while cursor != nil && pages < 30
        #expect(ids == written.map(\.id))
        #expect(pages > 1)
    }

    @Test func theLimitCapsAPageAt200AndTheResultLimitMayCutItShorter() throws {
        let h = try ToolHarness()
        try seed(h, (0..<205).map { "Fixed bug \($0)" })
        let reply = try h.call("query", ["limit": 200])
        let count = try #require(reply.structured?["count"]?.intValue)
        #expect(count > 40 && count <= 200)
        #expect(reply.structured?["next_cursor"] != .null)
        #expect(reply.size < MCPServer.maxResultCharacters)
        #expect(try h.call("query").structured?["count"]?.intValue == Int64(count))
    }

    @Test func queryRefusesBadInput() throws {
        let h = try ToolHarness()
        let cases: [(JSONValue, String)] = [
            (["from": "2026-10-29", "to": "2026-10-01"], "Not done: from must not be after to"),
            (["cursor": "not-a-cursor"], "Not done: cursor is not valid"),
            (["kinds": ["work.finished"]], "Not done: kinds[0]: must be one of "),
            (["families": ["everything"]], "Not done: families[0]: must be one of "),
            (["origins": "agent"], "Not done: origins: must be a list."),
            (["limit": 201], "Not done: limit: must be at most 200."),
            (["limit": 0], "Not done: limit: must be at least 1."),
            (["from": "last week"], "Not done: from: must be a date as YYYY-MM-DD."),
            (["statuses": ["proposed"], "extra": 1], "Not done: extra: is not a known argument."),
        ]
        for (arguments, expected) in cases {
            let reply = try h.call("query", arguments)
            #expect(reply.isError && reply.rpcError == nil, "\(arguments)")
            #expect(reply.text.hasPrefix(expected), "\(arguments) gave \(reply.text)")
        }
    }

    // MARK: summary

    @Test func summaryDefaultsToTheWeekAndKeepsUnknownApartFromZero() throws {
        let h = try ToolHarness()
        let empty = try h.call("summary")
        #expect(!empty.isError)
        #expect(empty.text.hasPrefix("Week: 2026-10-26 to 2026-10-29, 4 workdays."))
        #expect(empty.structured?["range"]?["label"] == "week")
        #expect(empty.structured?["entries"]?["value"] == .null)
        #expect(empty.structured?["findings"] == .array([]))
        try seed(h, ["Merged ACME-482913 retry budget", "Reviewed a design doc"])
        let some = try h.call("summary", ["range": "week"])
        #expect(some.structured?["entries"]?["value"] == 2)
        #expect(some.structured?["reviews"]?["value"] == 1)
        #expect(some.structured?["streak"] != nil && some.structured?["plan_done"] != nil)
    }

    @Test func summaryCarriesTheSection11FiguresAndTheReviewSentence() throws {
        let h = try ToolHarness()
        try seed(h, ["Merged ACME-482913 retry budget", "Reviewed a design doc"])
        let before = try h.call("summary")
        // Entries from the CLI are self-reported: a known zero agent entries. No PR, session or usage row exists, so
        // the other figures are null rather than 0.
        #expect(before.structured?["ai"]?["agent_entries"]?["value"] == 0)
        #expect(before.structured?["ai"]?["assisted_merges"]?["value"] == .null)
        #expect(before.structured?["ai"]?["session_length"]?["median_seconds"] == .null)
        #expect(before.structured?["ai"]?["cache_reuse"]?["percent"] == .null)
        #expect(before.structured?["ai"]?["model_mix"]?["models"] == .null)
        // An entry the agent logs over MCP is accepted with origin agent.
        _ = try h.call("log_entry", ["text": "Fixed a flaky test"])
        let after = try h.call("summary")
        #expect(after.structured?["ai"]?["agent_entries"]?["value"] == 1)
        #expect(after.structured?["review_sentence"]?["text"] == "Your agent logged 1 entry you accepted.")
        #expect(after.text.contains("The sentence your review needs\nYour agent logged 1 entry you accepted."))
        // Nothing logged at all: no sentence.
        let empty = try ToolHarness().call("summary")
        #expect(empty.structured?["review_sentence"]?["text"] == .null)
        #expect(empty.text.contains("The sentence your review needs: -"))
    }

    @Test func summaryTakesMonthCycleAndACustomRange() throws {
        let h = try ToolHarness()
        try seed(h, ["Fixed a bug"])
        for (range, label) in [("month", "month"), ("cycle", "cycle"), ("2026-10-26..2026-10-29", "2026-10-26..2026-10-29")] {
            let reply = try h.call("summary", ["range": .string(range)])
            #expect(!reply.isError && reply.structured?["range"]?["label"] == .string(label), "\(range)")
            #expect(reply.size < MCPServer.maxResultCharacters)
        }
        #expect(try h.call("summary", ["range": "2026-10-26..2026-10-29"]).structured?["entries"]?["value"] == 1)
    }

    @Test func summaryRefusesABadRange() throws {
        let h = try ToolHarness()
        let cases: [(String, String)] = [
            ("fortnight", "Not done: range: 'fortnight' is not valid; use week, month, cycle or YYYY-MM-DD..YYYY-MM-DD"),
            ("2026-10-29..2026-10-01", "Not done: range: the range starts after it ends"),
            ("2020-01-01..2026-10-29", "Not done: a summary covers at most 1100 days; use a shorter range"),
        ]
        for (range, expected) in cases {
            let reply = try h.call("summary", ["range": .string(range)])
            #expect(reply.isError && reply.text == expected, "\(range) gave \(reply.text)")
        }
    }

    // MARK: standup

    @Test func standupIsReadOnlyAndCarriesNoWitnessCode() throws {
        let h = try ToolHarness()
        let journal = try h.journal()
        _ = try journal.planAdd(title: "Draft the ADR", day: LocalDate("2026-10-30"), estimateMin: nil, origin: .selfReported, actor: .cli)
        try seed(h, ["Fixed flaky ledger test with deterministic clock ACME-482913"])
        let before = try h.eventCount()
        let reply = try h.call("standup")
        #expect(!reply.isError)
        #expect(reply.text.hasPrefix("*Thu 29 Oct*\nDone\n\u{2022} Fixed flaky ledger test with deterministic clock ACME-482913"))
        #expect(reply.text.contains("Next\n\u{2022} Draft the ADR"))
        #expect(reply.text.hasSuffix("Blockers: none"))
        #expect(!reply.text.contains("cadence ") && reply.structured?["text"]?.stringValue == reply.text)
        #expect(reply.structured?["day"] == "2026-10-29")
        #expect(try h.eventCount() == before)
        #expect(try h.events().allSatisfy { $0.type != "witness.checkpoint" })
        // The CLI's version of the same text only adds the witness line.
        let withCode = try journal.standup(nil, actor: .cli)
        #expect(withCode.text.hasPrefix(reply.text + "\n" + "cadence "))
    }

    @Test func standupForAPastDayAndTheRefusals() throws {
        let h = try ToolHarness()
        _ = try h.call("log_entry", ["text": "Paired on a fix", "date": "2026-10-28"])  // proposed, so not in the stand-up
        let past = try h.call("standup", ["date": "2026-10-28"])
        #expect(past.text.hasPrefix("*Wed 28 Oct*\nDone\n\u{2022} Nothing logged"))
        let future = try h.call("standup", ["date": "2026-10-30"])
        #expect(future.isError && future.text == "Not done: date: 2026-10-30 is in the future")
        #expect(try h.call("standup", ["date": "soon"]).isError)
    }

    // MARK: size, measured the way the server counts it

    /// Titles whose encoded form is longer than they look: quotes and backslashes are escaped, and a family emoji is one
    /// character to read but seven code points to count. 260 of them do not fit one result.
    static func awkwardLines(_ count: Int) -> [String] {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        return (0..<count).map { "Fixed \"retry\" budget \\ re\u{301}try \(family)\(family)\(family)\(family) \u{E9}tape number \($0)" }
    }

    @Test func aBigDayKeepsItsStructuredCopyAndSaysHowManyEntriesAreShown() throws {
        let h = try ToolHarness()
        let written = try seed(h, Self.awkwardLines(260))
        let reply = try h.call("get_day")
        #expect(!reply.isError && reply.structured != nil)
        #expect(reply.encodedSize <= MCPServer.maxResultCharacters, "\(reply.encodedSize)")
        #expect(!reply.text.contains("left out") && !reply.text.contains("cut at"))
        let shown = try #require(reply.structured?["entries"]?.arrayValue)
        #expect(shown.count < 260 && reply.structured?["entries_total"] == 260)
        #expect(shown.compactMap { $0["title"]?.stringValue } == written.prefix(shown.count).map(\.title))
        #expect(reply.text.contains("Showing \(shown.count) of 260 entries"))
    }

    @Test func aBigQueryKeepsItsStructuredCopyAndItsCursorOnEveryPage() throws {
        let h = try ToolHarness()
        let written = try seed(h, Self.awkwardLines(260))
        var titles: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            var arguments: [String: JSONValue] = [:]
            if let cursor { arguments["cursor"] = .string(cursor) }
            let reply = try h.call("query", .object(arguments))
            #expect(!reply.isError && reply.structured != nil, "page \(pages)")
            #expect(reply.encodedSize <= MCPServer.maxResultCharacters, "page \(pages): \(reply.encodedSize)")
            #expect(!reply.text.contains("left out") && !reply.text.contains("cut at"), "page \(pages)")
            titles += (reply.structured?["entries"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }
            cursor = reply.structured?["next_cursor"]?.stringValue
            // The text names the cursor the structured copy holds, so a client reading either can continue.
            if let cursor { #expect(reply.text.contains("call query again with cursor \(cursor)")) }
            pages += 1
        } while cursor != nil && pages < 30
        #expect(pages > 1)
        #expect(titles == written.map(\.title))
    }

    @Test func aBigStandupGivesWholeBulletsAndSaysHowManyAreLeftOut() throws {
        let h = try ToolHarness()
        let written = try seed(h, Self.awkwardLines(260))
        let reply = try h.call("standup")
        #expect(!reply.isError && reply.structured != nil)
        #expect(reply.encodedSize <= MCPServer.maxResultCharacters, "\(reply.encodedSize)")
        #expect(!reply.text.contains("cut at") && !reply.text.contains("left out"))
        #expect(reply.structured?["text"]?.stringValue == reply.text)
        let bullets = reply.text.split(separator: "\n").filter { $0.hasPrefix("\u{2022} ") }.map { String($0.dropFirst(2)) }
        let titles = Set(written.map(\.title))
        // Every bullet is a whole title, or the line that counts what was left out.
        let whole = bullets.filter { titles.contains($0) }
        let notes = bullets.filter { !titles.contains($0) }
        #expect(!whole.isEmpty && whole.count < 260)
        #expect(whole == written.prefix(whole.count).map(\.title))
        #expect(notes.count == 2 && notes.first == "\(260 - whole.count) more not shown; use query for this date", "\(notes)")
        #expect(notes.last == "Nothing planned")
        #expect(reply.text.hasPrefix("*Thu 29 Oct*\nDone\n") && reply.text.hasSuffix("Blockers: none"))
    }

    @Test func aStandupThatFitsIsGivenInFull() throws {
        let h = try ToolHarness()
        let written = try seed(h, Self.awkwardLines(12))
        let reply = try h.call("standup")
        let bullets = reply.text.split(separator: "\n").filter { $0.hasPrefix("\u{2022} ") }.map { String($0.dropFirst(2)) }
        #expect(bullets == written.map(\.title) + ["Nothing planned"])
        #expect(!reply.text.contains("not shown"))
    }

    // MARK: a store with nothing in it yet

    @Test func readsAndDryRunsOnAnEmptyStoreWriteNothingNotEvenTheGenesisEvent() throws {
        let h = try ToolHarness(empty: true)
        #expect(try h.eventCount() == 0)
        let meta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]
        for (tool, arguments) in [
            ("get_day", JSONValue.object([:])), ("query", ["from": "2026-10-01"]), ("summary", ["range": "cycle"]), ("standup", [:]),
            ("log_entries", ["transcript": "- Fixed a bug\n- Reviewed a doc"]), ("log_entries", ["transcript": "- Fixed a bug", "dry_run": true]),
        ] {
            let reply = try h.call(tool, arguments)
            #expect(!reply.isError, "\(tool): \(reply.text)")
            #expect(try h.eventCount() == 0, "\(tool) wrote to an empty ledger")
        }
        for uri in ["cadence://week/current", "cadence://day/2026-10-28"] {
            let reply = try h.send(method: "resources/read", params: ["uri": .string(uri), "_meta": meta])
            #expect(reply.rpcError == nil, "\(uri)")
        }
        #expect(try h.eventCount() == 0)
        // The first write starts the ledger, under the agent's own name.
        let logged = try h.call("log_entry", ["text": "Fixed a bug"])
        #expect(!logged.isError)
        let events = try h.events()
        #expect(events.map(\.type) == ["ledger.genesis", "entry.created"] && events.allSatisfy { $0.actor == .mcp })
        #expect(try h.call("log_entries", ["transcript": "- Reviewed a doc", "dry_run": false]).isError == false)
    }

    @Test func theSummaryOfAnEmptyStoreCallsPastWorkdaysBeforeTheLedgerNotUnsealed() throws {
        let h = try ToolHarness(empty: true)
        for range in ["week", "month", "cycle"] {
            let reply = try h.call("summary", ["range": .string(range)])
            #expect(!reply.isError, "\(range)")
            let sealed = try #require(reply.structured?["sealed_workdays"], "\(range)")
            #expect(sealed["value"] == .null && sealed["of"] == 0, "\(range): \(sealed)")
            let workdays = try #require(reply.structured?["range"]?["workdays"]?.intValue)
            #expect(sealed["before_ledger"]?.intValue == workdays && workdays > 0, "\(range): \(sealed)")
            #expect(!reply.text.contains("sealed 0 of"), "\(range): \(reply.text)")
            #expect(reply.text.contains("(\(workdays) before the ledger began)"), "\(range): \(reply.text)")
        }
        #expect(try h.eventCount() == 0)
    }

    // MARK: every tool

    @Test func readToolsNeverWriteAndNoResultPassesTheLimit() throws {
        let h = try ToolHarness()
        try seed(h, (0..<40).map { "Fixed bug \($0)" })
        _ = try h.call("log_entry", ["text": "Paired on a fix", "date": "2026-10-27"])
        let before = try h.eventCount()
        for (tool, arguments) in [("get_day", JSONValue.object([:])), ("query", ["from": "2026-10-01"]), ("summary", ["range": "cycle"]), ("standup", [:])] {
            let reply = try h.call(tool, arguments)
            #expect(!reply.isError && reply.size < MCPServer.maxResultCharacters, "\(tool)")
            #expect(reply.result?["resultType"] == "complete")
        }
        #expect(try h.eventCount() == before)
    }
}
