import Foundation
import Testing

@testable import CadenceCore

/// docs/SPEC.md section 10.1, rule by rule. The clock reads Monday 2026-09-21 19:43 in Kolkata.
@Suite struct EnvelopeIngestTests {
    static let window = IngestWindow(since: "2026-09-18", until: "2026-09-21")

    struct Fixture {
        let clock = ManualClock(TestStore.start)
        let store: SQLiteStore
        let journal: Journal
        let inbox = TestStore.tempDirectory().appendingPathComponent("inbox")

        init(hosts: [String] = []) throws {
            var config = Config.defaults(timezone: "Asia/Kolkata")
            config.hosts = hosts
            store = try TestStore.make(clock: clock, projector: LedgerProjector())
            journal = try Journal(store: store, config: config, clock: clock, ids: CountingIDs())
        }

        @discardableResult
        func ingest(_ records: [String], collector: String = "github", header: String? = nil) throws -> IngestReport {
            let head = header ?? EnvelopeIngestTests.header(collector)
            return try journal.ingest(
                envelope: Array(([head] + records).joined(separator: "\n").utf8), collector: collector,
                window: EnvelopeIngestTests.window, inbox: inbox)
        }

        func entry(ref: String) throws -> Entry {
            let id = try #require(try store.db.query("SELECT id FROM entries WHERE source_ref = ?", [.text(ref)]).first?.text("id"))
            return try journal.entry(id)
        }

        func lastEvent() throws -> Event { try #require(try store.head()) }

        func events(_ type: String) throws -> [Event] {
            try store.events(after: 0, limit: 10_000).filter { $0.type == type }
        }
    }

    static func header(_ collector: String = "github") -> String {
        #"{"cadence":"envelope/1","collector":"\#(collector)","run":"01JBY0M8R2","generated_at":"2026-09-21T16:10:02+05:30","window":{"since":"2026-09-18","until":"2026-09-21"}}"#
    }

    static let merged =
        #"{"type":"item","source_ref":"github:PR_kwDOAbc123:merged","kind":"pr.merged","occurred_at":"2026-09-21T16:02:11+05:30","title":"ACME-482913 Ship retry budget for capture path","links":[{"kind":"pr","url":"https://git.example.com/acme/ledger-core/pull/412"}],"attrs":{"repo":"acme/ledger-core","number":412,"additions":184,"deletions":37,"ai_assisted":true}}"#
    static let review =
        #"{"type":"item","source_ref":"github:PRR_kwDOAbc777","kind":"review.given","occurred_at":"2026-09-21T11:20:40+05:30","title":"ACME-000000 Idempotency keys for refunds","links":[{"kind":"pr","url":"https://git.example.com/acme/refunds/pull/88"}],"attrs":{"repo":"acme/refunds","number":88,"state":"APPROVED","comments":4}}"#
    static let usage =
        #"{"type":"genai.usage","source_ref":"claude-code:2026-09-18:model-a","day":"2026-09-18","tool":"claude-code","model":"model-a","sessions":5,"requests":212,"tokens":{"in":48210,"out":96115,"cache_read":8120400,"cache_write":402118}}"#
    static let span =
        #"{"type":"presence.span","source_ref":"powerlog:2026-09-18T09:12","start":"2026-09-18T09:12:00+05:30","end":"2026-09-18T19:40:00+05:30"}"#
    static let leave = #"{"type":"leave","source_ref":"leave:2026-09-25","day":"2026-09-25","kind":"leave_planned","label":"Planned leave"}"#

    static func item(_ ref: String, title: String = "Ship it", extra: String = "") -> String {
        #"{"type":"item","source_ref":"\#(ref)","kind":"pr.merged","day":"2026-09-21","title":"\#(title)"\#(extra)}"#
    }

    // MARK: - The example envelope

    @Test func theSpecExampleBecomesEntriesUsagePresenceAndLeave() throws {
        let f = try Fixture()
        let report = try f.ingest([Self.merged, Self.review, Self.usage, Self.span, Self.leave])
        #expect(report.status == "ok")
        #expect(report.counts == ["records": 5, "created": 5, "updated": 0, "unchanged": 0, "ignored": 0, "skipped": 0, "warnings": 0])
        #expect(report.inbox == nil)

        let pr = try f.entry(ref: "github:PR_kwDOAbc123:merged")
        #expect(pr.title == "Ship retry budget for capture path")
        #expect(pr.ticket == Ticket(key: "ACME-482913", class: .assigned))
        #expect(pr.family == .delivery)
        #expect(pr.origin == .collected && pr.source == "github" && pr.status == .accepted)
        #expect(pr.occurredAt == "2026-09-21T16:02:11+05:30" && pr.day == "2026-09-21")
        #expect(pr.links == [Link(kind: .pr, url: "https://git.example.com/acme/ledger-core/pull/412")])
        #expect(pr.attrs["number"] == 412 && pr.attrs["ai_assisted"] == true)
        #expect(!pr.backfilled && !pr.afterSeal)

        let review = try f.entry(ref: "github:PRR_kwDOAbc777")
        #expect(review.ticket == Ticket(key: "ACME-000000", class: .selfInitiated))
        #expect(review.title == "Idempotency keys for refunds")

        let usage = try #require(try f.store.db.query("SELECT * FROM genai_usage").first)
        #expect(usage.text("source") == "github" && usage.text("model") == "model-a")
        #expect(usage.int("sessions") == 5 && usage.int("tokens_cache_read") == 8_120_400)

        let spans = try f.store.db.query("SELECT * FROM presence_spans")
        #expect(spans.map { $0.text("source") } == ["collected"])
        #expect(spans.first?.text("start_at") == "2026-09-18T09:12:00+05:30")

        let day = try #require(try f.store.db.query("SELECT kind, label FROM days WHERE date = '2026-09-25'").first)
        #expect(day.text("kind") == "leave_planned" && day.text("label") == "Planned leave")

        let created = try f.events("entry.created")
        #expect(created.allSatisfy { $0.actor == .collector("github") })
    }

    @Test func everyRunWritesOneIngestRunWithWindowCountsAndErrors() throws {
        let f = try Fixture()
        try f.ingest([Self.merged, #"{"type":"mystery","source_ref":"x"}"#])
        let run = try f.lastEvent()
        #expect(run.type == "ingest.run" && run.actor == .collector("github"))
        #expect(run.subject?.hasPrefix("run:") == true)
        let payload = try IngestRun(json: run.data)
        #expect(payload.collector == "github" && payload.since == "2026-09-18" && payload.until == "2026-09-21")
        #expect(payload.status == "ok")
        #expect(payload.counts["created"] == 1 && payload.counts["skipped"] == 1 && payload.counts["records"] == 2)
        #expect(payload.errors == ["line 3: type: 'mystery' is not a record type"])
    }

    // MARK: - Idempotency

    @Test func theSameEnvelopeTwiceWritesOnlyTheRun() throws {
        let f = try Fixture()
        try f.ingest([Self.merged, Self.review, Self.usage, Self.span, Self.leave])
        let before = try f.store.eventCount()
        let dump = try f.store.projectionDump()
        let again = try f.ingest([Self.merged, Self.review, Self.usage, Self.span, Self.leave])
        #expect(again.count("unchanged") == 5 && again.count("created") == 0 && again.count("updated") == 0)
        #expect(try f.store.eventCount() == before + 1)
        #expect(try f.lastEvent().type == "ingest.run")
        #expect(try f.store.projectionDump() == dump)
    }

    @Test func changedContentIsAnEntryUpdatedByTheCollector() throws {
        let f = try Fixture()
        try f.ingest([Self.item("github:1", title: "First title", extra: #","attrs":{"comments":1}"#)])
        let report = try f.ingest([Self.item("github:1", title: "Better title", extra: #","attrs":{"comments":3}"#)])
        #expect(report.count("updated") == 1)
        let update = try #require(try f.events("entry.updated").last)
        #expect(update.actor == .collector("github"))
        let changes = try Changes(json: update.data).fields
        #expect(Set(changes.keys) == ["title", "attrs"])
        #expect(changes["title"] == Change(old: "First title", new: "Better title"))
        let entry = try f.entry(ref: "github:1")
        #expect(entry.title == "Better title" && entry.attrs["comments"] == 3)
        #expect(entry.origin == .collected)
    }

    @Test func aSecondRecordForTheSameKeyInOneEnvelopeIsSkippedSoTheEnvelopeSettles() throws {
        let f = try Fixture()
        let usageB = Self.usage.replacingOccurrences(of: "model-a\",\"sessions\":5", with: "model-a\",\"sessions\":2")
            .replacingOccurrences(of: "claude-code:2026-09-18:model-a", with: "claude-code:2026-09-18:model-a:b")
        let leaveB = Self.leave.replacingOccurrences(of: "leave:2026-09-25", with: "leave:b").replacingOccurrences(of: "Planned leave", with: "Other")
        let records = [Self.item("github:1", title: "One"), Self.item("github:1", title: "Two"), Self.usage, usageB, Self.leave, leaveB]
        let first = try f.ingest(records)
        #expect(first.count("created") == 3 && first.count("skipped") == 3)
        #expect(first.problems == [
            "line 3: repeats what line 2 already says about source_ref github:1",
            "line 5: repeats what line 4 already says about the usage row for 2026-09-18, claude-code, model-a",
            "line 7: repeats what line 6 already says about the day 2026-09-25",
        ])
        #expect(try f.entry(ref: "github:1").title == "One")
        let again = try f.ingest(records)
        #expect(again.count("unchanged") == 3 && again.count("skipped") == 3 && again.count("updated") == 0)
    }

    @Test func theActorMustBeThisCollectorOrItsImport() throws {
        let f = try Fixture()
        #expect(throws: CadenceError.self) {
            try f.journal.ingest(envelope: Array(Self.header().utf8), collector: "github", window: Self.window, actor: .importer("jira"))
        }
        #expect(throws: CadenceError.self) {
            try f.journal.ingest(envelope: Array(Self.header().utf8), collector: "github", window: Self.window, actor: .cli)
        }
    }

    // MARK: - Ownership

    @Test func aFieldYouEditedIsYoursAndCollectorChangesToItAreIgnored() throws {
        let f = try Fixture()
        try f.ingest([Self.item("github:1", title: "Collector title", extra: #","quantity":1"#)])
        let id = try f.entry(ref: "github:1").id
        try f.store.append([
            EventPayload.entryUpdated(Changes(fields: ["title": Change(old: "Collector title", new: "My title")]))
                .draft(actor: .app, id: id)
        ])

        let titleOnly = try f.ingest([Self.item("github:1", title: "Collector retitled", extra: #","quantity":1"#)])
        #expect(titleOnly.count("ignored") == 1)
        #expect(try f.entry(ref: "github:1").title == "My title")

        let both = try f.ingest([Self.item("github:1", title: "Collector retitled", extra: #","quantity":2"#)])
        #expect(both.count("updated") == 1)
        let changes = try Changes(json: try #require(try f.events("entry.updated").last).data).fields
        #expect(Set(changes.keys) == ["quantity"])
        let entry = try f.entry(ref: "github:1")
        #expect(entry.title == "My title" && entry.quantity == 2)
    }

    @Test func anImportNeverOwnsAField() throws {
        let f = try Fixture()
        try f.ingest([Self.item("x:1", title: "One")])
        let text = ([Self.header()] + [Self.item("x:1", title: "Two")]).joined(separator: "\n")
        try f.journal.ingest(envelope: Array(text.utf8), collector: "github", window: Self.window, actor: .importer("github"))
        #expect(try f.entry(ref: "x:1").title == "Two")
        #expect(try f.ingest([Self.item("x:1", title: "Three")]).count("updated") == 1)
        #expect(try f.entry(ref: "x:1").title == "Three")
    }

    @Test func aCollectorOnlyEditsEntriesItCreated() throws {
        let f = try Fixture()
        try f.ingest([Self.item("shared:1", title: "From github")])
        let report = try f.ingest([Self.item("shared:1", title: "From jira")], collector: "jira")
        #expect(report.count("skipped") == 1)
        #expect(report.problems == ["line 2: item.source_ref: belongs to an entry another writer created"])
        #expect(try f.entry(ref: "shared:1").title == "From github")
    }

    @Test func theLedgerRefusesACollectorEditToAnEntryItDidNotCreate() throws {
        let f = try Fixture()
        let mine = try f.journal.log(LogRequest(text: "Paired with the team"), actor: .cli, origin: .selfReported)
        #expect(throws: CadenceError.self) {
            try f.store.append([
                EventPayload.entryUpdated(Changes(fields: ["title": Change(old: .string(mine.title), new: "Taken")]))
                    .draft(actor: .collector("github"), id: mine.id)
            ])
        }
        try f.ingest([Self.item("github:1")])
        let theirs = try f.entry(ref: "github:1")
        #expect(throws: CadenceError.self) {
            try f.store.append([
                EventPayload.entryUpdated(Changes(fields: ["title": Change(old: "Ship it", new: "Taken")]))
                    .draft(actor: .collector("jira"), id: theirs.id)
            ])
        }
    }

    @Test func collectorsNeverDelete() throws {
        let f = try Fixture()
        try f.ingest([Self.item("github:1"), Self.item("github:2", title: "Opened")])
        let report = try f.ingest([Self.item("github:1")])
        #expect(report.count("unchanged") == 1)
        #expect(try f.entry(ref: "github:2").status == .accepted)
        #expect(try f.events("entry.status").isEmpty)
    }

    @Test func aDismissedEntryStaysDismissed() throws {
        let f = try Fixture()
        try f.ingest([Self.item("github:1")])
        let id = try f.entry(ref: "github:1").id
        _ = try f.journal.setStatus(entryID: id, to: .dismissed, note: nil, actor: .app)
        try f.ingest([Self.item("github:1", title: "Retitled")])
        let entry = try f.entry(ref: "github:1")
        #expect(entry.status == .dismissed && entry.title == "Retitled")
    }

    // MARK: - After wrap-up

    @Test func anItemForASealedDayIsMarkedAfterWrapUp() throws {
        let f = try Fixture()
        _ = try f.journal.seal(LocalDate("2026-09-21")!, actor: .cli)
        try f.ingest([Self.item("github:late")])
        let entry = try f.entry(ref: "github:late")
        #expect(entry.afterSeal && entry.status == .accepted)
    }

    @Test func anItemForAnEarlierDayIsBackfilled() throws {
        let f = try Fixture()
        try f.ingest([#"{"type":"item","source_ref":"github:old","kind":"pr.merged","day":"2026-09-18","title":"Older"}"#])
        let entry = try f.entry(ref: "github:old")
        #expect(entry.backfilled && entry.occurredAt == nil && entry.day == "2026-09-18")
    }

    // MARK: - Validation: records

    @Test func unknownTypesAndUnknownFieldsAreSkippedAndTheEnvelopeIsKept() throws {
        let f = try Fixture()
        let report = try f.ingest([
            Self.item("github:1"),
            #"{"type":"meeting","source_ref":"m:1"}"#,
            Self.item("github:2", extra: #","colour":"red""#),
        ])
        #expect(report.count("created") == 1 && report.count("skipped") == 2)
        #expect(report.problems == ["line 3: type: 'meeting' is not a record type", "line 4: item.colour: unknown field"])
        let kept = try #require(report.inbox)
        #expect(kept.lastPathComponent == "github-\(report.runID).jsonl")
        #expect(try Data(contentsOf: kept).count > 0)
        let mode = try FileManager.default.attributesOfItem(atPath: kept.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let why = try String(contentsOf: kept.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        #expect(why.contains("item.colour: unknown field"))
    }

    @Test func rawOutputIsKeptOnlyWhenTheEnvelopeIs() throws {
        let f = try Fixture()
        let head = Self.header("github")
        let raw = Array("raw bytes the envelope was made from".utf8)
        func run(_ records: [String], skipped: [String] = []) throws -> IngestReport {
            try f.journal.ingest(
                envelope: Array(([head] + records).joined(separator: "\n").utf8), collector: "github", window: Self.window,
                inbox: f.inbox, skipped: skipped, raw: raw)
        }
        let clean = try run([Self.item("github:1")])
        #expect(clean.inbox == nil && clean.raw == nil)

        let bad = try run([Self.item("github:2"), "{not json"])
        let kept = try #require(bad.raw)
        #expect(kept.lastPathComponent == "github-\(bad.runID).raw")
        #expect(try Data(contentsOf: kept) == Data(raw))
        let mode = try FileManager.default.attributesOfItem(atPath: kept.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let why = try String(contentsOf: kept.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        #expect(why.contains("raw output: github-\(bad.runID).raw"))

        // Rows a map already dropped keep the envelope too, and the raw output with it.
        let dropped = try run([Self.item("github:3")], skipped: ["record 2: tokens.out: must not be negative"])
        #expect(dropped.inbox != nil && dropped.raw != nil)

        // A runner can also keep raw output on its own when there is no envelope.
        let failure = try f.journal.recordIngestFailure(
            collector: "github", window: Self.window, error: "map: nothing readable", inbox: f.inbox, raw: raw)
        let alone = try #require(failure.raw)
        #expect(failure.inbox == nil && alone.lastPathComponent == "github-\(failure.runID).raw")
        let plain = try f.journal.recordIngestFailure(collector: "github", window: Self.window, error: "exit status 1")
        #expect(plain.raw == nil)
    }

    @Test func badRecordsAreSkippedWithTheirReason() throws {
        let cases: [(String, String)] = [
            ("{not json", "is not valid JSON"),
            (Self.item("r", extra: #","quantity":1.5"#), "numbers must be integers"),
            (Self.item("r", extra: #","duration_s":-5"#), "item.duration_s: must not be negative"),
            (#"{"type":"item","source_ref":"r","kind":"pr.merged","title":"No day"}"#, "item.occurred_at: or day is required"),
            (#"{"type":"item","source_ref":"r","kind":"pr.merged","title":"x","occurred_at":"2026-09-21T10:00:00"}"#, "must be an RFC 3339 time with an offset"),
            (#"{"type":"item","source_ref":"r","kind":"pr.merged","title":"x","occurred_at":"2026-09-22T10:00:00+05:30"}"#, "is in the future"),
            (#"{"type":"item","source_ref":"r","kind":"pr.merged","title":"x","day":"2026-09-22"}"#, "is in the future"),
            (#"{"type":"item","source_ref":"r","kind":"pr.merged","title":"x","day":"2026-09-20","occurred_at":"2026-09-21T10:00:00+05:30"}"#, "is not on 2026-09-20"),
            (#"{"type":"item","source_ref":"r","kind":"pr.party","title":"x","day":"2026-09-21"}"#, "is not an entry kind"),
            (#"{"type":"item","kind":"pr.merged","title":"x","day":"2026-09-21"}"#, "item.source_ref: is required"),
            (#"{"type":"item","source_ref":"has space","kind":"pr.merged","title":"x","day":"2026-09-21"}"#, "item.source_ref"),
            (Self.item("r", title: #"\u0007"#), "item.title: is empty"),
            (Self.item("r", extra: #","attrs":{"nested":{"a":1}}"#), "item.attrs.nested: must be a string, integer or boolean"),
            (Self.item("r", extra: #","attrs":{"big":"\#(String(repeating: "x", count: 2100))"}"#), "item.attrs: must stay under 2 KB"),
            (Self.item("r", extra: #","ticket":"no key here""#), "item.ticket: holds no ticket key"),
            (Self.item("r", extra: #","tags":["two words"]"#), "item.tags[0]"),
            (#"{"type":"genai.usage","source_ref":"u","day":"2026-09-21","tool":"claude code"}"#, "genai.usage.tool"),
            (#"{"type":"genai.usage","source_ref":"u","day":"2026-09-21","tool":"t","tokens":{"in":1,"total":2}}"#, "genai.usage.tokens.total: unknown field"),
            (#"{"type":"presence.span","source_ref":"p","start":"2026-09-21T12:00:00+05:30","end":"2026-09-21T11:00:00+05:30"}"#, "must not be before start"),
            (#"{"type":"leave","source_ref":"l","day":"2026-09-25","kind":"workday"}"#, "leave.kind"),
            ("[1,2]", "type: is required"),
        ]
        for (line, reason) in cases {
            let f = try Fixture()
            let report = try f.ingest([line])
            #expect(report.count("skipped") == 1, "\(line)")
            #expect(report.problems.first?.contains(reason) == true, "\(line) gave \(report.problems)")
            #expect(try f.events("entry.created").isEmpty)
        }
    }

    @Test func titlesLoseControlCharactersAndAreCutAt200() throws {
        let f = try Fixture()
        let long = String(repeating: "a", count: 250)
        try f.ingest([Self.item("t:1", title: #"Fix\tthe\u0000 bug"#), Self.item("t:2", title: long)])
        #expect(try f.entry(ref: "t:1").title == "Fix the bug")
        #expect(try f.entry(ref: "t:2").title.count == 200)
    }

    @Test func linksMustBeHttpsOrHttpOnAListedHost() throws {
        let f = try Fixture(hosts: ["Git.Example.Com"])
        let links = #","links":[{"url":"javascript:alert(1)"},{"url":"http://other.example.com/a"},{"url":"http://git.example.com/acme/x/pull/9"},{"kind":"doc","url":"https://docs.example.com/a"},{"url":"ftp://example.com/f"},{"url":"https://user:secret@git.example.com/a"},{"kind":"video","url":"https://example.com/v"}]"#
        let report = try f.ingest([Self.item("l:1", extra: links)])
        #expect(report.count("created") == 1 && report.count("warnings") == 5 && report.count("skipped") == 0)
        #expect(report.inbox == nil)
        #expect(try f.entry(ref: "l:1").links == [
            Link(kind: .pr, url: "http://git.example.com/acme/x/pull/9"), Link(kind: .doc, url: "https://docs.example.com/a"),
        ])
        #expect(report.problems.first == "line 2: warning: links[0]: only https links (or http on a host in config.hosts) are kept; dropped")
    }

    @Test func aStatedTicketWinsAndTheTitleKeepsItsText() throws {
        let f = try Fixture()
        try f.ingest([Self.item("k:1", title: "Retry budget", extra: #","ticket":"ACME-123456""#)])
        let entry = try f.entry(ref: "k:1")
        #expect(entry.ticket == Ticket(key: "ACME-123456", class: .assigned) && entry.title == "Retry budget")
    }

    // MARK: - Validation: the envelope

    @Test func anUnreadableHeaderWritesOnlyAFailedRun() throws {
        let headers = [
            (#"{"cadence":"envelope/2","collector":"github","run":"r","generated_at":"2026-09-21T16:10:02+05:30","window":{"since":"2026-09-18","until":"2026-09-21"}}"#, "header.cadence"),
            (Self.header("jira"), "header.collector: names 'jira', but this is collector 'github'"),
            (#"{"cadence":"envelope/1","collector":"github"}"#, "header.run: is required"),
            ("not json", "header: is not valid JSON"),
        ]
        for (header, reason) in headers {
            let f = try Fixture()
            let before = try f.store.eventCount()
            let report = try f.ingest([Self.merged], header: header)
            #expect(report.status == "error" && report.counts.isEmpty)
            #expect(report.problems.first?.contains(reason) == true, "\(report.problems)")
            #expect(try f.store.eventCount() == before + 1)
            let run = try IngestRun(json: try f.lastEvent().data)
            #expect(run.status == "error" && run.counts.isEmpty)
            #expect(report.inbox != nil)
        }
    }

    @Test func anEnvelopeOverTheLimitsIsRefusedWhole() throws {
        let f = try Fixture()
        let empty = try f.journal.ingest(envelope: Array("\n\n".utf8), collector: "github", window: Self.window)
        #expect(empty.status == "error" && empty.problems == ["the envelope is empty"])

        let many = [Self.header()] + Array(repeating: Self.item("same"), count: 20_001)
        let tooMany = try f.journal.ingest(envelope: Array(many.joined(separator: "\n").utf8), collector: "github", window: Self.window)
        #expect(tooMany.status == "error" && tooMany.problems == ["the envelope has more than 20,000 records"])

        let big = [UInt8](repeating: 0x20, count: 10 * 1024 * 1024 + 1)
        let tooBig = try f.journal.ingest(envelope: big, collector: "github", window: Self.window, inbox: f.inbox)
        #expect(tooBig.status == "error" && tooBig.problems == ["the envelope is larger than 10 MB"])
        #expect(tooBig.inbox == nil)
        #expect(try f.events("entry.created").isEmpty)
    }

    @Test func blankLinesAndCRLFAreAccepted() throws {
        let f = try Fixture()
        let text = Self.header() + "\r\n\r\n" + Self.item("c:1") + "\r\n"
        let report = try f.journal.ingest(envelope: Array(text.utf8), collector: "github", window: Self.window)
        #expect(report.count("created") == 1 && report.count("records") == 1)
    }

    @Test func aFailedRunCanBeRecordedWithoutAnEnvelope() throws {
        let f = try Fixture()
        let report = try f.journal.recordIngestFailure(collector: "github", window: Self.window, error: "exit status 1")
        #expect(report.status == "error")
        let run = try IngestRun(json: try f.lastEvent().data)
        #expect(run.errors == ["exit status 1"] && run.status == "error")
        #expect(throws: CadenceError.self) { try f.journal.recordIngestFailure(collector: "Bad Name", window: Self.window, error: "x") }
    }

    // MARK: - Presence, usage and leave

    @Test func collectedPresenceFillsGapsAndNeverOverridesObservedSpans() throws {
        let f = try Fixture()
        try f.store.append([
            EventPayload.presenceSpan(PresenceSpanPayload(
                day: "2026-09-18", tz: "Asia/Kolkata", start: "2026-09-18T10:00:00+05:30", end: "2026-09-18T12:00:00+05:30",
                source: .input)).draft(actor: .app),
            EventPayload.presenceSpan(PresenceSpanPayload(
                day: "2026-09-18", tz: "Asia/Kolkata", start: "2026-09-18T12:00:30+05:30", end: "2026-09-18T15:00:00+05:30",
                source: .unlock)).draft(actor: .app),
        ])
        let span = #"{"type":"presence.span","source_ref":"p:1","start":"2026-09-18T09:00:00+05:30","end":"2026-09-18T18:00:00+05:30"}"#
        try f.ingest([span])
        let rows = try f.store.db.query("SELECT start_at, end_at, source FROM presence_spans ORDER BY start_at")
        #expect(rows.map { "\($0.text("start_at")!)-\($0.text("end_at")!) \($0.text("source")!)" } == [
            "2026-09-18T09:00:00+05:30-2026-09-18T10:00:00+05:30 collected",
            "2026-09-18T10:00:00+05:30-2026-09-18T12:00:00+05:30 input",
            "2026-09-18T12:00:30+05:30-2026-09-18T15:00:00+05:30 unlock",
            "2026-09-18T15:00:00+05:30-2026-09-18T18:00:00+05:30 collected",
        ])
        let again = try f.ingest([span])
        #expect(again.count("unchanged") == 1)
        let wider = try f.ingest([#"{"type":"presence.span","source_ref":"p:1","start":"2026-09-18T09:00:00+05:30","end":"2026-09-18T19:00:00+05:30"}"#])
        #expect(wider.count("created") == 1)
        #expect(try f.store.db.query("SELECT COUNT(*) AS n FROM presence_spans").first?.int("n") == 5)
    }

    @Test func aSpanIsCutAtTheDayBoundary() throws {
        let f = try Fixture()
        let report = try f.ingest([#"{"type":"presence.span","source_ref":"p:1","start":"2026-09-18T22:00:00+05:30","end":"2026-09-19T05:00:00+05:30"}"#])
        #expect(report.count("created") == 1)
        let rows = try f.store.db.query("SELECT day, start_at, end_at FROM presence_spans ORDER BY start_at")
        #expect(rows.map { "\($0.text("day")!) \($0.text("start_at")!)-\($0.text("end_at")!)" } == [
            "2026-09-18 2026-09-18T22:00:00+05:30-2026-09-19T04:00:00+05:30",
            "2026-09-19 2026-09-19T04:00:00+05:30-2026-09-19T05:00:00+05:30",
        ])
    }

    @Test func presenceOnADayRecordedInAnotherZoneIsPlacedAndFinishes() throws {
        let f = try Fixture()
        try f.store.append([
            EventPayload.dayDeclared(DayDeclared(day: "2026-09-18", tz: "Pacific/Kiritimati", kind: .workday)).draft(actor: .app)
        ])
        let report = try f.ingest([#"{"type":"presence.span","source_ref":"p:1","start":"2026-09-18T20:00:00+05:30","end":"2026-09-18T22:00:00+05:30"}"#])
        #expect(report.count("created") + report.count("skipped") == 1)
        let dump = try f.store.projectionDump()
        try f.store.rebuild()
        #expect(try f.store.projectionDump() == dump)
    }

    @Test func usageIsOneRowPerSourceAndChangesReplaceIt() throws {
        let f = try Fixture()
        try f.ingest([Self.usage])
        let changed = Self.usage.replacingOccurrences(of: #""sessions":5"#, with: #""sessions":6"#)
        let report = try f.ingest([changed])
        #expect(report.count("updated") == 1)
        let rows = try f.store.db.query("SELECT sessions FROM genai_usage")
        #expect(rows.map { $0.int("sessions") } == [6])

        let estimated = try f.ingest([changed.replacingOccurrences(of: #""sessions":6"#, with: #""sessions":6,"cost_micros":1200,"estimated":true"#)])
        #expect(estimated.count("updated") == 1)
        let last = try GenAIUsage(json: try #require(try f.events("genai.usage").last).data)
        #expect(last.estimated && last.costMicros == 1200)

        let unknown = try f.ingest([#"{"type":"genai.usage","source_ref":"u","day":"2026-09-18","tool":"chat","tokens":{"out":10}}"#])
        #expect(unknown.count("created") == 1)
        let row = try #require(try f.store.db.query("SELECT * FROM genai_usage WHERE tool = 'chat'").first)
        #expect(row.text("model") == "*" && row.int("sessions") == nil && row.int("tokens_out") == 10)
    }

    @Test func importedUsageCarriesTheImportSource() throws {
        let f = try Fixture()
        let text = ([Self.header("october-app")] + [Self.usage]).joined(separator: "\n")
        try f.journal.ingest(envelope: Array(text.utf8), collector: "october-app", window: Self.window, actor: .importer("october-app"))
        #expect(try f.store.db.query("SELECT source FROM genai_usage").map { $0.text("source") } == ["import:october-app"])
        #expect(try f.events("genai.usage").first?.actor == .importer("october-app"))
    }

    @Test func leaveNeverOverridesADayYouDeclared() throws {
        let f = try Fixture()
        try f.journal.declare(LocalDate("2026-09-25")!, kind: .holiday, label: "Festival", actor: .app)
        let report = try f.ingest([Self.leave])
        #expect(report.count("ignored") == 1)
        let day = try #require(try f.store.db.query("SELECT kind, label FROM days WHERE date = '2026-09-25'").first)
        #expect(day.text("kind") == "holiday" && day.text("label") == "Festival")
    }

    @Test func leaveTheCollectorDeclaredFollowsItsSource() throws {
        let f = try Fixture()
        try f.ingest([Self.leave])
        #expect(try f.ingest([Self.leave]).count("unchanged") == 1)
        let changed = try f.ingest([Self.leave.replacingOccurrences(of: "leave_planned", with: "leave_unplanned")])
        #expect(changed.count("updated") == 1)
        #expect(try f.store.db.query("SELECT kind FROM days WHERE date = '2026-09-25'").first?.text("kind") == "leave_unplanned")
    }

    // MARK: - Rebuild

    @Test func projectionsRebuildByteForByteAfterIngest() throws {
        let f = try Fixture()
        try f.ingest([Self.merged, Self.review, Self.usage, Self.span, Self.leave])
        try f.ingest([Self.item("github:PR_kwDOAbc123:merged", title: "Renamed")])
        let dump = try f.store.projectionDump()
        try f.store.rebuild()
        #expect(try f.store.projectionDump() == dump)
    }
}
