import Foundation
import Testing

@testable import CadenceCore

@Suite struct JournalTests {
    static let zoneID = "Asia/Kolkata"

    /// The test clock reads Monday 2026-09-21 19:43 in Kolkata, so today is 2026-09-21 and 2026-09-20 is a Sunday.
    struct Fixture {
        let clock: ManualClock
        let store: SQLiteStore
        let journal: Journal
        let today = LocalDate("2026-09-21")!
        let yesterday = LocalDate("2026-09-20")!

        init(config: Config = Config.defaults(timezone: JournalTests.zoneID)) throws {
            clock = ManualClock(TestStore.start)
            store = try TestStore.make(clock: clock, projector: LedgerProjector())
            journal = try Journal(store: store, config: config, clock: clock, ids: CountingIDs())
        }
    }

    static func request(_ text: String) -> LogRequest { LogRequest(text: text) }

    // MARK: log

    @Test func genesisIsWrittenOnceFromConfig() throws {
        var config = Config.defaults(timezone: Self.zoneID)
        config.profile.name = "Sample Person"
        let f = try Fixture(config: config)
        #expect(try f.store.eventCount() == 1)
        let genesis = try #require(try f.store.events(after: 0, limit: 1).first)
        #expect(genesis.type == "ledger.genesis")
        #expect(genesis.data.objectValue?["profile"]?.objectValue?["name"]?.stringValue == "Sample Person")
        #expect(genesis.data.objectValue?["profile"]?.objectValue?["role"] == nil)
        _ = try Journal(store: f.store, config: config, clock: f.clock, ids: CountingIDs())
        #expect(try f.store.eventCount() == 1)
    }

    @Test func aJournalForReadingLeavesAnEmptyLedgerEmpty() throws {
        let clock = ManualClock(TestStore.start)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        let config = Config.defaults(timezone: Self.zoneID)
        let reading = try Journal(store: store, config: config, clock: clock, ids: CountingIDs(), actor: .mcp, writesGenesis: false)
        #expect(try store.eventCount() == 0)
        let day = reading.today()
        #expect(try reading.dayView(day).entries.isEmpty)
        _ = try reading.summary(SummaryRange.week)
        _ = try reading.standupText(nil)
        #expect(try reading.query(EntryQuery(from: day, to: day)).entries.isEmpty)
        #expect(try store.eventCount() == 0)
        // Opened the usual way, the same ledger gets its genesis event, written by the actor that opened it.
        _ = try Journal(store: store, config: config, clock: clock, ids: CountingIDs(), actor: .mcp)
        let events = try store.events(after: 0, limit: 10)
        #expect(events.map(\.type) == ["ledger.genesis"] && events[0].actor == .mcp)
    }

    @Test func logParsesTheLine() throws {
        let f = try Fixture()
        let entry = try f.journal.log(
            Self.request("Merged ACME-482913 retry budget at 10:30 ~45m #quality"), actor: .cli, origin: .selfReported)
        #expect(entry.family == .delivery)
        #expect(entry.ticket == Ticket(key: "ACME-482913", class: .assigned))
        #expect(entry.day == "2026-09-21")
        #expect(entry.occurredAt == "2026-09-21T10:30:00+05:30")
        #expect(entry.durationS == 2700)
        #expect(entry.tags == ["quality"])
        #expect(entry.title.contains("retry budget"))
        #expect(entry.status == .accepted)
        #expect(entry.origin == .selfReported)
        #expect(!entry.backfilled && !entry.afterSeal)
        #expect(entry.export == .include)
        let stored = try f.journal.entry(entry.id)
        #expect(stored == entry)
    }

    @Test func requestFieldsOverrideTheParse() throws {
        let f = try Fixture()
        var request = Self.request("Fixed ACME-100001 flaky test yesterday 20m")
        request.kind = .reviewGiven
        request.date = f.today
        request.occurredAt = "09:15"
        request.ticket = "ACME-000000"
        request.quantity = 3
        request.durationMin = 90
        request.note = "paired with a teammate"
        request.links = [Link(kind: .pr, url: "https://git.example.com/acme/core/pull/7")]
        let entry = try f.journal.log(request, actor: .cli, origin: .selfReported)
        #expect(entry.kind == .reviewGiven)
        #expect(entry.family == .review)
        #expect(entry.day == "2026-09-21")
        #expect(entry.occurredAt == "2026-09-21T09:15:00+05:30")
        #expect(entry.ticket == Ticket(key: "ACME-000000", class: .selfInitiated))
        #expect(entry.quantity == 3)
        #expect(entry.durationS == 5400)
        #expect(entry.attrs["note"] == .string("paired with a teammate"))
        #expect(entry.links.count == 1)
    }

    @Test func selfInitiatedTicketMovesDeliveryToInitiative() throws {
        let f = try Fixture()
        let entry = try f.journal.log(Self.request("Shipped ACME-000000 cleanup"), actor: .cli, origin: .selfReported)
        #expect(entry.family == .initiative)
    }

    @Test func rfc3339OccurredAtIsStoredInProfileZone() throws {
        let f = try Fixture()
        var request = Self.request("Wrote the design note")
        request.occurredAt = "2026-09-21T04:30:00Z"
        let entry = try f.journal.log(request, actor: .cli, origin: .selfReported)
        #expect(entry.occurredAt == "2026-09-21T10:00:00+05:30")
    }

    @Test func titleIsCleanedAndBounded() throws {
        let f = try Fixture()
        let entry = try f.journal.log(
            Self.request("Wrote\u{0007} the " + String(repeating: "long ", count: 80)), actor: .cli, origin: .selfReported)
        #expect(entry.title.count <= 200)
        #expect(!entry.title.unicodeScalars.contains { $0.properties.generalCategory == .control })
        #expect(throws: CadenceError.self) {
            try f.journal.log(Self.request("   \u{0007}  "), actor: .cli, origin: .selfReported)
        }
    }

    @Test func invalidFieldsAreValidationErrors() throws {
        let f = try Fixture()
        func fails(_ change: (inout LogRequest) -> Void) {
            var request = Self.request("Did a thing")
            change(&request)
            do {
                _ = try f.journal.log(request, actor: .cli, origin: .selfReported)
                Issue.record("expected a validation error")
            } catch {
                guard case .validation = error else { Issue.record("wrong error \(error)"); return }
            }
        }
        fails { $0.occurredAt = "25:99" }
        fails { $0.ticket = "no ticket here" }
        fails { $0.quantity = 0 }
        fails { $0.durationMin = 0 }
        fails { $0.durationMin = 721 }
        fails { $0.date = LocalDate("2026-09-22") }
        fails { $0.links = [Link(kind: .other, url: "http://insecure.example.com")] }
        #expect(try f.store.eventCount() == 1)
    }

    // One link rule for the CLI, MCP and envelope paths: https (or http on a configured host), at most 2,048
    // characters, a host, no credentials, no spaces, control or bidi characters.
    @Test func aLinkMustPassTheSameRuleAsAnEnvelopeLink() throws {
        let f = try Fixture()
        let tooLong = "https://example.com/" + String(repeating: "a", count: 2048)
        let refused: [String] = [
            "https://user:secret@git.example.com/a", "https://user@git.example.com/a", "https://example.com/a\u{0007}b",
            "https://example.com/\u{202E}evil", "https://example.com/\u{2066}x", "https://example.com/\u{200F}", "https://exa mple.com/a",
            "https://example.com/a\nb", "https://example.com/\u{85}", tooLong, "https:///path", "https://", "javascript:alert(1)",
            "ftp://example.com/f", "HTTP://example.com/x", "file:///etc/passwd",
        ]
        for url in refused {
            var request = Self.request("Did a thing")
            request.links = [Link(kind: .other, url: url)]
            #expect(throws: CadenceError.self, "\(url.prefix(40))") {
                try f.journal.log(request, actor: .cli, origin: .selfReported)
            }
            #expect(throws: CadenceError.self, "\(url.prefix(40))") { try f.journal.preview(request, origin: .agent) }
        }
        #expect(try f.store.eventCount() == 1)

        // Exactly 2,048 characters is the longest link kept.
        let longest = "https://example.com/" + String(repeating: "a", count: 2048 - "https://example.com/".count)
        #expect(longest.count == 2048)
        for url in [longest, "https://git.example.com/acme/x/pull/9", "HTTPS://Git.Example.com/acme/x/pull/10", "https://docs.example.com/caf\u{E9}?q=a%20b#top"] {
            var request = Self.request("Did a thing")
            request.links = [Link(kind: .other, url: url)]
            let entry = try f.journal.log(request, actor: .cli, origin: .selfReported)
            #expect(entry.links.map(\.url) == [url])
        }
    }

    @Test func aLinkMessageSaysWhatIsWrong() throws {
        let f = try Fixture()
        func message(_ url: String) -> String? {
            var request = Self.request("Did a thing")
            request.links = [Link(kind: .other, url: url)]
            do {
                _ = try f.journal.log(request, actor: .cli, origin: .selfReported)
                return nil
            } catch { return error.message }
        }
        #expect(message("http://example.com/x") == "link: only https links are accepted")
        #expect(message("https://u:p@example.com/x") == "link: must not carry a user name or password")
        #expect(message("https://example.com/a b") == "link: must not hold spaces, control or bidirectional characters")
        #expect(message("https://example.com/\u{202E}") == "link: must not hold spaces, control or bidirectional characters")
        #expect(message("https://example.com/" + String(repeating: "a", count: 2048)) == "link: at most 2048 characters")
        #expect(message("https:///x") == "link: needs a host")
    }

    @Test func httpIsKeptOnlyOnAHostInConfigHosts() throws {
        var config = Config.defaults(timezone: Self.zoneID)
        config.hosts = ["Git.Example.com"]
        let f = try Fixture(config: config)
        var request = Self.request("Did a thing")
        request.links = [Link(kind: .pr, url: "http://git.example.com/acme/x/pull/9")]
        #expect(try f.journal.log(request, actor: .cli, origin: .selfReported).links.count == 1)
        request.links = [Link(kind: .pr, url: "http://other.example.com/acme/x/pull/9")]
        #expect(throws: CadenceError.self) { try f.journal.log(request, actor: .cli, origin: .selfReported) }
    }

    @Test func aLinkTypedInTheTextIsKeptOnlyWhenItPassesTheRule() throws {
        let f = try Fixture()
        let entry = try f.journal.log(
            Self.request("Reviewed https://git.example.com/acme/x/pull/9 and https://bob:pw@git.example.com/acme/x/pull/10"),
            actor: .cli, origin: .selfReported)
        #expect(entry.links.map(\.url) == ["https://git.example.com/acme/x/pull/9"])
    }

    @Test func agentWritingAPastDayIsProposedAndBackfilled() throws {
        let f = try Fixture()
        var request = Self.request("Reviewed the retry budget doc")
        request.date = f.yesterday
        let entry = try f.journal.log(request, actor: .mcp, origin: .agent)
        #expect(entry.status == .proposed)
        #expect(entry.backfilled)
        #expect(entry.origin == .agent)
        #expect(entry.occurredAt == nil)
    }

    @Test func agentWritingTodayIsAccepted() throws {
        let f = try Fixture()
        let entry = try f.journal.log(Self.request("Fixed the flaky test"), actor: .mcp, origin: .agent)
        #expect(entry.status == .accepted)
        #expect(!entry.backfilled)
        #expect(entry.occurredAt == "2026-09-21T19:43:20+05:30")
    }

    @Test func selfWritingAPastDayIsAcceptedAndBackfilled() throws {
        let f = try Fixture()
        var request = Self.request("Fixed the flaky test")
        request.date = f.yesterday
        let entry = try f.journal.log(request, actor: .cli, origin: .selfReported)
        #expect(entry.status == .accepted)
        #expect(entry.backfilled)
    }

    @Test func afterSealIsSetWhenTheDayIsSealed() throws {
        let f = try Fixture()
        _ = try f.journal.log(Self.request("Fixed the flaky test"), actor: .cli, origin: .selfReported)
        let head = try #require(try f.store.head()).hash
        try f.store.append([
            EventPayload.daySealed(
                DaySealed(
                    day: "2026-09-21", tz: Self.zoneID, counts: ["delivery": 1],
                    plan: PlanCounts(done: 0, slipped: 0, dropped: 0, moved: 0, open: 0), head: head)
            ).draft(actor: .app)
        ])
        let late = try f.journal.log(Self.request("Merged a late fix"), actor: .cli, origin: .selfReported)
        #expect(late.afterSeal)
        var other = Self.request("Fixed an older thing")
        other.date = f.yesterday
        #expect(try !f.journal.log(other, actor: .cli, origin: .selfReported).afterSeal)
    }

    @Test func notesExportAsDigest() throws {
        let f = try Fixture()
        let entry = try f.journal.log(Self.request("Thinking about the roadmap"), actor: .cli, origin: .selfReported)
        #expect(entry.kind == .note)
        #expect(entry.export == .digest)
    }

    @Test func oneLogIsOneEvent() throws {
        let f = try Fixture()
        _ = try f.journal.log(Self.request("Fixed the flaky test"), actor: .cli, origin: .selfReported)
        #expect(try f.store.eventCount() == 2)
        let event = try #require(try f.store.head())
        #expect(event.type == "entry.created")
        #expect(event.actor == .cli)
    }

    // MARK: plan

    @Test func planAddAssignsPositionsAndTickets() throws {
        let f = try Fixture()
        let first = try f.journal.planAdd(
            title: "Ship ACME-482913 retry budget", day: nil, estimateMin: 60, origin: .selfReported, actor: .cli)
        let second = try f.journal.planAdd(title: "Write the RFC", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        let other = try f.journal.planAdd(title: "Other day", day: f.yesterday, estimateMin: nil, origin: .suggested, actor: .mcp)
        #expect(first.position == 1 && second.position == 2 && other.position == 1)
        #expect(first.day == "2026-09-21" && other.day == "2026-09-20")
        #expect(first.ticket == Ticket(key: "ACME-482913", class: .assigned))
        #expect(first.estimateMin == 60)
        #expect(first.status == .open)
        #expect(first.plannedAt == "2026-09-21T19:43:20+05:30")
        #expect(other.origin == .suggested)
        #expect(throws: CadenceError.self) { try f.journal.planAdd(title: " ", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli) }
    }

    @Test func planResolveRules() throws {
        let f = try Fixture()
        let task = try f.journal.planAdd(title: "Write the RFC", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        let entry = try f.journal.log(Self.request("Wrote the RFC"), actor: .cli, origin: .selfReported)

        do {
            _ = try f.journal.planResolve(taskID: task.id, status: .slipped, reason: nil, note: nil, links: [], actor: .cli)
            Issue.record("slip without a reason must fail")
        } catch { guard case .validation = error else { Issue.record("\(error)"); return } }

        do {
            _ = try f.journal.planResolve(taskID: "NOPE", status: .done, reason: nil, note: nil, links: [], actor: .cli)
            Issue.record("unknown task must fail")
        } catch { guard case .notFound = error else { Issue.record("\(error)"); return } }

        do {
            _ = try f.journal.planResolve(taskID: task.id, status: .done, reason: nil, note: nil, links: ["NOPE"], actor: .cli)
            Issue.record("unknown linked entry must fail")
        } catch { guard case .notFound = error else { Issue.record("\(error)"); return } }

        let done = try f.journal.planResolve(
            taskID: task.id, status: .done, reason: nil, note: "finished", links: [entry.id], actor: .cli)
        #expect(done.status == .done)
        #expect(done.linkedEntries == [entry.id])
        #expect(done.reasonNote == "finished")
        #expect(done.resolvedAt != nil)

        let slipped = try f.journal.planResolve(
            taskID: task.id, status: .slipped, reason: "reprioritised", note: nil, links: [], actor: .cli)
        #expect(slipped.status == .slipped && slipped.reason == "reprioritised")
        #expect(throws: CadenceError.self) {
            try f.journal.planResolve(taskID: task.id, status: .open, reason: nil, note: nil, links: [], actor: .cli)
        }
    }

    // MARK: status

    @Test func setStatusTransitions() throws {
        let f = try Fixture()
        var request = Self.request("Reviewed the doc")
        request.date = f.yesterday
        let proposed = try f.journal.log(request, actor: .mcp, origin: .agent)
        #expect(proposed.status == .proposed)

        let accepted = try f.journal.setStatus(entryID: proposed.id, to: .accepted, note: "ok", actor: .cli)
        #expect(accepted.status == .accepted)
        #expect(accepted.origin == .agent)
        let dismissed = try f.journal.setStatus(entryID: proposed.id, to: .dismissed, note: nil, actor: .cli)
        #expect(dismissed.status == .dismissed)
        #expect(try f.journal.setStatus(entryID: proposed.id, to: .accepted, note: nil, actor: .cli).status == .accepted)

        let events = try f.journal.history(subject: "entry:\(proposed.id)")
        #expect(events.map(\.type) == ["entry.created", "entry.status", "entry.status", "entry.status"])
    }

    @Test func illegalTransitionsAndUnknownIds() throws {
        let f = try Fixture()
        let accepted = try f.journal.log(Self.request("Fixed the flaky test"), actor: .cli, origin: .selfReported)
        for target in [EntryStatus.proposed, .accepted, .deleted] {
            do {
                _ = try f.journal.setStatus(entryID: accepted.id, to: target, note: nil, actor: .cli)
                Issue.record("accepted to \(target) must fail")
            } catch { guard case .validation = error else { Issue.record("\(error)"); return } }
        }
        do {
            _ = try f.journal.setStatus(entryID: "NOPE", to: .accepted, note: nil, actor: .cli)
            Issue.record("unknown entry must fail")
        } catch { guard case .notFound = error else { Issue.record("\(error)"); return } }
        do {
            _ = try f.journal.entry("NOPE")
            Issue.record("unknown entry must fail")
        } catch { guard case .notFound = error else { Issue.record("\(error)"); return } }
    }

    @Test func inboxListsOnlyProposals() throws {
        let f = try Fixture()
        _ = try f.journal.log(Self.request("Fixed the flaky test"), actor: .cli, origin: .selfReported)
        var request = Self.request("Reviewed the doc")
        request.date = f.yesterday
        let proposed = try f.journal.log(request, actor: .mcp, origin: .agent)
        #expect(try f.journal.inbox().map(\.id) == [proposed.id])
        _ = try f.journal.setStatus(entryID: proposed.id, to: .accepted, note: nil, actor: .cli)
        #expect(try f.journal.inbox().isEmpty)
    }

    // MARK: days

    @Test func dayViewForAnEmptyWeekendAndWorkday() throws {
        let f = try Fixture()
        let sunday = try f.journal.dayView(f.yesterday)
        #expect(sunday.day.kind == .weekend)
        #expect(sunday.day.firstActivity == nil && sunday.day.lastActivity == nil)
        #expect(sunday.tasks.isEmpty && sunday.entries.isEmpty && sunday.presence.isEmpty)
        #expect(sunday.day.tz == Self.zoneID)
        let monday = try f.journal.dayView(f.today)
        #expect(monday.day.kind == .workday)
        #expect(try f.store.db.first("SELECT COUNT(*) AS n FROM days")?.int("n") == 0)
    }

    @Test func aDeclaredWorkingWeekendShowsAsAWorkday() throws {
        let f = try Fixture()
        try f.journal.declare(f.yesterday, kind: .workday, label: "Release weekend", actor: .cli)
        #expect(try f.journal.dayView(f.yesterday).day.kind == .workday)
        try f.journal.declare(f.today, kind: .leavePlanned, label: nil, actor: .cli)
        #expect(try f.journal.dayView(f.today).day.kind == .leavePlanned)
    }

    @Test func startEndAndDeclare() throws {
        let f = try Fixture()
        try f.journal.startDay(nil, at: "09:05", actor: .cli)
        try f.journal.endDay(nil, at: "17:40", actor: .cli)
        var view = try f.journal.dayView(f.today)
        #expect(view.day.firstActivity == "2026-09-21T09:05:00+05:30")
        #expect(view.day.lastActivity == "2026-09-21T17:40:00+05:30")
        let start = try #require(try f.journal.history(subject: "day:2026-09-21").first)
        #expect(start.data.objectValue?["source"]?.stringValue == "manual")

        try f.journal.declare(f.yesterday, kind: .leaveUnplanned, label: "unwell", actor: .cli)
        view = try f.journal.dayView(f.yesterday)
        #expect(view.day.kind == .leaveUnplanned && view.day.label == "unwell")

        #expect(throws: CadenceError.self) { try f.journal.startDay(f.yesterday, at: nil, actor: .cli) }
        #expect(throws: CadenceError.self) { try f.journal.startDay(nil, at: "9am", actor: .cli) }
    }

    @Test func dayViewCollectsPlanEntriesAndPresence() throws {
        let f = try Fixture()
        _ = try f.journal.planAdd(title: "Write the RFC", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        let entry = try f.journal.log(Self.request("Fixed the flaky test"), actor: .cli, origin: .selfReported)
        try f.store.append([
            EventPayload.presenceSpan(
                PresenceSpanPayload(
                    day: "2026-09-21", tz: Self.zoneID, start: "2026-09-21T10:00:00+05:30",
                    end: "2026-09-21T12:00:00+05:30", source: .input)
            ).draft(actor: .app)
        ])
        let view = try f.journal.dayView(f.today)
        #expect(view.tasks.count == 1)
        #expect(view.entries.map(\.id) == [entry.id])
        #expect(view.presence == [PresenceRange(start: "2026-09-21T10:00:00+05:30", end: "2026-09-21T12:00:00+05:30", source: .input)])
        #expect(view.day.firstActivity == "2026-09-21T10:00:00+05:30")
    }

    // MARK: query

    @Test func queryFiltersAndOrdering() throws {
        let f = try Fixture()
        var older = Self.request("Reviewed the doc")
        older.date = f.yesterday
        let a = try f.journal.log(older, actor: .cli, origin: .selfReported)
        var late = Self.request("Fixed the flaky test")
        late.occurredAt = "15:00"
        let c = try f.journal.log(late, actor: .cli, origin: .selfReported)
        var early = Self.request("Merged the retry budget")
        early.occurredAt = "09:00"
        let b = try f.journal.log(early, actor: .cli, origin: .selfReported)
        var agentPast = Self.request("Reviewed another doc")
        agentPast.date = f.yesterday
        let proposed = try f.journal.log(agentPast, actor: .mcp, origin: .agent)
        let dismissed = try f.journal.log(agentPast, actor: .mcp, origin: .agent)
        _ = try f.journal.setStatus(entryID: dismissed.id, to: .dismissed, note: nil, actor: .cli)

        let all = try f.journal.query(EntryQuery(from: f.yesterday, to: f.today))
        #expect(all.next == nil)
        // Ordered by day, then occurred_at (missing first), then creation.
        #expect(all.entries.map(\.id) == [a.id, proposed.id, b.id, c.id])

        #expect(try f.journal.query(EntryQuery(from: f.today, to: f.today)).entries.map(\.id) == [b.id, c.id])
        #expect(try f.journal.query(EntryQuery(from: f.yesterday, to: f.today, kinds: [.reviewGiven])).entries.map(\.id) == [a.id, proposed.id])
        #expect(try f.journal.query(EntryQuery(from: f.yesterday, to: f.today, families: [.delivery])).entries.map(\.id) == [b.id, c.id])
        #expect(try f.journal.query(EntryQuery(from: f.yesterday, to: f.today, origins: [.agent])).entries.map(\.id) == [proposed.id])
        #expect(try f.journal.query(EntryQuery(from: f.yesterday, to: f.today, statuses: [.dismissed])).entries.map(\.id) == [dismissed.id])
        #expect(try f.journal.query(EntryQuery(from: f.yesterday, to: f.today, statuses: [.proposed])).entries.map(\.id) == [proposed.id])
        #expect(throws: CadenceError.self) { try f.journal.query(EntryQuery(from: f.today, to: f.yesterday)) }
    }

    @Test func queryPagesWithACursor() throws {
        let f = try Fixture()
        var ids: [String] = []
        for n in 0..<450 {
            f.clock.advance(by: 1)
            ids.append(try f.journal.log(Self.request("Fixed thing \(n)"), actor: .cli, origin: .selfReported).id)
        }
        let day = f.today
        var q = EntryQuery(from: day, to: day)
        let one = try f.journal.query(q)
        #expect(one.entries.count == 200)
        let cursor1 = try #require(one.next)
        #expect(Data(base64Encoded: cursor1) != nil)
        q.cursor = cursor1
        let two = try f.journal.query(q)
        #expect(two.entries.count == 200)
        q.cursor = two.next
        let three = try f.journal.query(q)
        #expect(three.entries.count == 50)
        #expect(three.next == nil)
        #expect((one.entries + two.entries + three.entries).map(\.id) == ids)

        q.cursor = "not a cursor"
        #expect(throws: CadenceError.self) { try f.journal.query(q) }
        var big = EntryQuery(from: day, to: day)
        big.limit = 5000
        #expect(try f.journal.query(big).entries.count == 200)
    }

    @Test func rebuildKeepsEveryRead() throws {
        let f = try Fixture()
        _ = try f.journal.planAdd(title: "Write the RFC", day: nil, estimateMin: 30, origin: .selfReported, actor: .cli)
        _ = try f.journal.log(Self.request("Fixed the flaky test"), actor: .cli, origin: .selfReported)
        try f.journal.declare(f.yesterday, kind: .holiday, label: nil, actor: .cli)
        let before = try f.journal.dayView(f.today)
        try f.store.rebuild()
        #expect(try f.journal.dayView(f.today) == before)
    }
}
