import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The Log (docs/SPEC.md section 4.6): filters, paging newest first, the entry's origin and history, the empty states
/// and discreet mode.
@MainActor @Suite struct LogTests {
    typealias Home = DayStoreLoaderTests.Home

    static let gb = Locale(identifier: "en_GB")
    static let today = LocalDate("2026-09-21")!

    static func day(_ text: String) -> LocalDate { LocalDate(text)! }

    /// Waits on the main actor, which stays free to publish, until `condition` holds.
    func until(timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: filters

    @Test func filtersComposeIntoTheQuery() {
        let filter = LogFilter(search: "  retry budget ", family: .review, origin: .collected)
        let query = filter.query(from: Self.day("2026-09-01"), to: Self.today, cursor: "abc", limit: 50)
        #expect(query.from == Self.day("2026-09-01"))
        #expect(query.to == Self.today)
        #expect(query.families == [.review])
        #expect(query.origins == [.collected])
        #expect(query.kinds.isEmpty)
        #expect(query.statuses == [.accepted])
        #expect(query.search == "retry budget")
        #expect(query.searchNotes)
        #expect(query.cursor == "abc")
        #expect(query.limit == 50)
        #expect(!filter.isClear)

        let clear = LogFilter(search: "   ").query(from: Self.today, to: Self.today)
        #expect(clear.families.isEmpty)
        #expect(clear.origins.isEmpty)
        #expect(clear.search == nil)
        #expect(clear.limit == EntryQuery.maxLimit)
        #expect(LogFilter(search: " ").isClear)
    }

    @Test func chipsAndSearchNarrowARealStoreAndSearchReadsNotes() throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        _ = try journal.log(LogRequest(text: "Reviewed the ACME-101 change", kind: .reviewGiven), actor: .cli, origin: .selfReported)
        _ = try journal.log(
            LogRequest(text: "Wrote the capture runbook", kind: .workDone, note: "mention the retry budget"), actor: .cli,
            origin: .selfReported)
        _ = try journal.log(LogRequest(text: "Proposed by an agent", proposed: true), actor: .mcp, origin: .agent)

        func titles(_ filter: LogFilter) throws -> [String] {
            try LogPage.read(journal, filter: filter, before: nil).entries.map(\.title)
        }
        #expect(try titles(LogFilter()).sorted() == ["Reviewed the ACME-101 change", "Wrote the capture runbook"])
        #expect(try titles(LogFilter(family: .review)) == ["Reviewed the ACME-101 change"])
        #expect(try titles(LogFilter(search: "acme-101")) == ["Reviewed the ACME-101 change"])
        #expect(try titles(LogFilter(search: "retry budget")) == ["Wrote the capture runbook"])
        #expect(try titles(LogFilter(origin: .agent)).isEmpty)
        #expect(try titles(LogFilter(search: "runbook", family: .review)).isEmpty)
    }

    @Test func pagesWalkBackNewestFirstInWholeDays() throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        var logged: [String] = []
        for back in stride(from: 40, through: 0, by: -1) {
            let day = Self.today.adding(days: -back)
            for n in 0..<2 {
                let entry = try journal.log(
                    LogRequest(text: "ACME item \(back)-\(n)", date: day, occurredAt: String(format: "1%d:00", n)), actor: .cli,
                    origin: .selfReported)
                logged.append(entry.id)
            }
        }
        var seen: [Entry] = []
        var before: LocalDate?
        var pages = 0
        repeat {
            let page = try LogPage.read(journal, filter: LogFilter(), before: before, target: 10, windowDays: 3)
            seen += page.entries
            before = page.before
            pages += 1
        } while before != nil && pages < 50
        #expect(pages > 1)
        #expect(seen.map(\.id) == logged.reversed())
        #expect(seen.first?.day == Self.today.description)
    }

    // MARK: the detail

    @Test func historyIsOldestFirstWithActorsInWords() throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let idea = try journal.log(
            LogRequest(text: "Started the ACME replay idea", kind: .initiativeStarted, proposed: true), actor: .mcp, origin: .agent)
        _ = try journal.setStatus(entryID: idea.id, to: .accepted, note: nil, actor: .app)
        _ = try journal.setStatus(entryID: idea.id, to: .dismissed, note: nil, actor: .cli)
        _ = try journal.setStatus(entryID: idea.id, to: .accepted, note: nil, actor: .app)
        let entry = try journal.entry(idea.id)
        let events = try journal.history(subject: "entry:\(idea.id)")

        let detail = LogDetail(entry: entry, events: events, zone: journal.zone, discreet: false, locale: Self.gb)
        #expect(detail.versions.map(\.what) == ["Proposed by an agent", "You accepted it", "You dismissed it", "You restored it"])
        #expect(detail.versions.map(\.id) == events.map(\.seq))
        #expect(detail.versions.allSatisfy { $0.title == "Started the ACME replay idea" })
        #expect(detail.versions.map(\.time) == Array(repeating: "19:43", count: 4))
        #expect(detail.kind == "Initiative")
        #expect(detail.origin == "Origin is set once and never changes: agent.")
        #expect(entry.origin == .agent)
    }

    @Test func historyNamesCollectorsEditsAndOtherDays() throws {
        let entry = Entry(
            id: "e1", day: "2026-09-20", kind: .prMerged, family: .delivery, title: "Merged: ACME spool batching",
            occurredAt: "2026-09-20T17:08:00+05:30", origin: .collected, source: "github")
        let created = Event(
            v: 1, seq: 4, id: "x", at: "2026-09-20T11:38:00.000Z", actor: .collector("github"), type: "entry.created",
            subject: "entry:e1", data: entry.json, dataDigest: "", prev: "", hash: "")
        let changes = Changes(fields: ["title": Change(old: .string(entry.title), new: .string("Merged: ACME spool drain batching"))])
        let updated = Event(
            v: 1, seq: 9, id: "y", at: "2026-09-21T04:30:00.000Z", actor: .collector("github"), type: "entry.updated",
            subject: "entry:e1", data: changes.json, dataDigest: "", prev: "", hash: "")
        let zone = TimeZone(identifier: "Asia/Kolkata")!

        let detail = LogDetail(entry: entry, events: [created, updated], zone: zone, discreet: false, locale: Self.gb)
        #expect(detail.versions.map(\.what) == ["Collected from GitHub", "GitHub changed the title"])
        #expect(detail.versions.map(\.title) == ["Merged: ACME spool batching", "Merged: ACME spool drain batching"])
        #expect(detail.versions.map(\.time) == ["17:08", "Mon 21 Sep, 10:00"])
        #expect(detail.origin == "Origin is set once and never changes: collected, GitHub.")
        #expect(LogDetail.footnote == "Edits add a version. Nothing is overwritten.")
    }

    // MARK: rows, empty states and discreet mode

    @Test func rowsAreGroupedByDayWithTheirParts() {
        let entries = [
            Entry(
                id: "a", day: "2026-09-21", kind: .reviewGiven, family: .review, title: "Reviewed the ACME-7 change",
                occurredAt: "2026-09-21T15:30:00+05:30", ticket: Ticket(key: "ACME-7", class: .assigned), origin: .collected,
                source: "github"),
            Entry(
                id: "b", day: "2026-09-20", kind: .incidentHandled, family: .ownership, title: "Handled the ACME alert",
                occurredAt: "2026-09-20T18:40:00+05:30", ticket: Ticket(key: "ACME-9", class: .assigned), origin: .selfReported,
                afterSeal: true),
            Entry(id: "c", day: "2026-09-20", kind: .note, family: .presence, title: "A note", origin: .selfReported),
        ]
        let content = LogContent(entries: entries, today: Self.today, discreet: false, locale: Self.gb)
        #expect(content.days.map(\.title) == ["Today", "Sun 20 Sep"])
        #expect(content.days.map { $0.rows.map(\.id) } == [["a"], ["b", "c"]])
        let alert = content.days[1].rows[0]
        #expect(alert.time == "18:40")
        #expect(alert.afterWrapUp)
        #expect(alert.ticket == "ACME-9")
        #expect(alert.spoken == "18:40, Ownership, Handled the ACME alert, After wrap-up, ticket ACME-9, Logged by you")
        // A key the title carries is not shown twice, and a missing time is "-", never invented.
        #expect(content.days[0].rows[0].ticket == nil)
        #expect(content.days[1].rows[1].time == "-")
    }

    @Test func discreetModeHidesTitlesAndTickets() {
        let entries = (0..<3).map { n in
            Entry(
                id: "e\(n)", day: "2026-09-21", kind: .workDone, family: .delivery, title: "ACME secret \(n)",
                ticket: Ticket(key: "ACME-\(n)", class: .assigned), origin: .selfReported)
        }
        let content = LogContent(entries: entries, today: Self.today, discreet: true, locale: Self.gb)
        #expect(content.days[0].rows.map(\.title) == ["Item 1", "Item 2", "Item 3"])
        #expect(content.days[0].rows.allSatisfy { $0.ticket == nil && !$0.spoken.contains("ACME") })

        let created = Event(
            v: 1, seq: 2, id: "x", at: "2026-09-21T10:00:00.000Z", actor: .cli, type: "entry.created", subject: "entry:e1",
            data: entries[1].json, dataDigest: "", prev: "", hash: "")
        let detail = LogDetail(entry: entries[1], events: [created], zone: .gmt, index: 1, discreet: true, locale: Self.gb)
        #expect(detail.title == "Item 2")
        #expect(detail.versions.map(\.title) == ["Item 2"])
        #expect(detail.versions.map(\.what) == ["You logged it"])
    }

    @Test func nothingMatchesThenClearFiltersBringsEverythingBack() async throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        _ = try journal.log(LogRequest(text: "Wrote the ACME runbook"), actor: .cli, origin: .selfReported)
        let model = LogModel(location: .found(home.roots), clock: DayStoreLoaderTests.FixedClock())
        model.start()
        #expect(await until { model.reads == 1 })
        #expect(model.entries.map(\.title) == ["Wrote the ACME runbook"])

        model.setOrigin(.agent)
        #expect(await until { model.reads == 2 })
        #expect(model.entries.isEmpty)
        #expect(model.phase == .loaded)
        #expect(!model.filter.isClear)
        #expect(LogContent.nothingMatches == "Nothing matches.")
        #expect(LogContent.clearFilters == "Clear filters")

        model.clearFilters()
        #expect(await until { model.reads == 3 })
        #expect(model.filter.isClear)
        #expect(model.entries.count == 1)
    }

    @Test func typingIsDebouncedIntoOneSearch() async throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        _ = try journal.log(LogRequest(text: "Wrote the ACME runbook"), actor: .cli, origin: .selfReported)
        _ = try journal.log(LogRequest(text: "Reviewed the replay change"), actor: .cli, origin: .selfReported)
        let model = LogModel(location: .found(home.roots), clock: DayStoreLoaderTests.FixedClock())
        model.start()
        #expect(await until { model.reads == 1 })
        for text in ["r", "ru", "run", "runb"] { model.setSearch(text) }
        #expect(model.searchText == "runb")
        #expect(model.filter.search == "")
        #expect(await until { model.reads == 2 })
        #expect(model.filter.search == "runb")
        #expect(model.entries.map(\.title) == ["Wrote the ACME runbook"])
        try? await Task.sleep(for: LogModel.debounce * 2)
        #expect(model.reads == 2)
    }

    @Test func noStoreIsAnEmptyLogNotAFailure() async {
        let home = Home()
        defer { home.remove() }
        let model = LogModel(location: .found(home.roots), clock: DayStoreLoaderTests.FixedClock())
        model.start()
        #expect(await until { model.reads == 1 })
        #expect(model.phase == .loaded)
        #expect(model.entries.isEmpty)
        #expect(model.filter.isClear)
    }

    @Test func openingAnEntryReadsItsHistory() async throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let entry = try journal.log(LogRequest(text: "Wrote the ACME runbook"), actor: .cli, origin: .selfReported)
        let model = LogModel(location: .found(home.roots), clock: DayStoreLoaderTests.FixedClock())
        model.start()
        #expect(await until { model.reads == 1 })
        model.open(entry.id)
        #expect(await until { model.opened != nil })
        #expect(model.opened?.entry.id == entry.id)
        #expect(model.opened?.events.map(\.type) == ["entry.created"])
        model.open(nil)
        #expect(model.opened == nil)
    }

    // MARK: editing the open entry

    /// A Log reading `home`, an `AppState` writing to it, and `entry` open in the detail.
    func opened(_ home: Home, _ entry: Entry) async throws -> (LogModel, AppState) {
        let clock = DayStoreLoaderTests.FixedClock()
        let app = AppState(
            model: DayModel(loader: home.loader),
            writer: AppWriter(location: .found(home.roots), clock: clock, poster: AppWriterTests.CountingPoster()), clock: clock)
        let model = LogModel(location: .found(home.roots), clock: clock)
        model.start()
        #expect(await until { model.reads == 1 })
        model.open(entry.id)
        #expect(await until { model.opened?.entry.id == entry.id })
        return (model, app)
    }

    @Test func editTitleAddsAVersionTheHistoryShows() async throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let entry = try journal.log(LogRequest(text: "Wrote the ACME runbook"), actor: .cli, origin: .selfReported)
        let (model, app) = try await opened(home, entry)
        model.beginEdit()
        #expect(model.edit == TitleEdit(entry: entry.id, draft: "Wrote the ACME runbook"))
        model.setDraft("Wrote the ACME failover runbook")
        #expect(await model.saveEdit(through: app))
        #expect(model.edit == nil)
        #expect(await until { model.opened?.events.count == 2 })
        let opened = try #require(model.opened)
        #expect(opened.entry.title == "Wrote the ACME failover runbook")
        #expect(opened.entry.origin == .selfReported)
        let detail = LogDetail(entry: opened.entry, events: opened.events, zone: .gmt, discreet: false, locale: Self.gb)
        #expect(detail.versions.map(\.what) == ["You logged it", "You changed the title"])
        #expect(detail.versions.map(\.title) == ["Wrote the ACME runbook", "Wrote the ACME failover runbook"])
        #expect(LogDetail.footnote == "Edits add a version. Nothing is overwritten.")
        #expect(model.entries.map(\.title) == ["Wrote the ACME failover runbook"])
    }

    @Test func changeKindMovesTheFamilyAndAddsAVersion() async throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let entry = try journal.log(
            LogRequest(text: "Went through the ACME replay change", kind: .workDone), actor: .cli, origin: .selfReported)
        #expect(entry.family == .delivery)
        let (model, app) = try await opened(home, entry)
        #expect(await model.changeKind(.reviewGiven, through: app))
        let changed = try journal.entry(entry.id)
        #expect(changed.kind == .reviewGiven)
        #expect(changed.family == .review)
        #expect(changed.origin == .selfReported)
        #expect(await until { model.opened?.entry.family == .review })
        let opened = try #require(model.opened)
        let detail = LogDetail(entry: opened.entry, events: opened.events, zone: .gmt, discreet: false, locale: Self.gb)
        #expect(detail.kind == "Review")
        #expect(detail.versions.map(\.what) == ["You logged it", "You changed the kind"])
        #expect(model.kindProblem == nil)
    }

    @Test func anEmptyTitleIsRefusedInTheDetailAndKeepsTheField() async throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let entry = try journal.log(LogRequest(text: "Wrote the ACME runbook"), actor: .cli, origin: .selfReported)
        let (model, app) = try await opened(home, entry)
        model.beginEdit()
        model.setDraft(" ")
        #expect(await !model.saveEdit(through: app))
        #expect(model.edit?.draft == " ")
        #expect(model.edit?.problem == TitleEdit.emptyTitle)
        #expect(try journal.history(subject: "entry:\(entry.id)").count == 1)
        // Opening another entry, or closing the detail, leaves the edit.
        model.open(nil)
        #expect(model.edit == nil)
    }

    @Test func kindsAreOfferedOnceEachUnderTheirWorkKindExceptMeasuredOnes() {
        let groups = TitleEdit.kindsByFamily
        let typed = EntryKind.allCases.filter { !TitleEdit.measured.contains($0) }
        #expect(groups.map(\.family) == Family.allCases.filter { family in typed.contains { $0.defaultFamily == family } })
        #expect(groups.flatMap(\.kinds).count == typed.count)
        #expect(Set(groups.flatMap(\.kinds)) == Set(typed))
        #expect(!groups.flatMap(\.kinds).contains(.presenceSpan) && !groups.flatMap(\.kinds).contains(.genaiSession))
        #expect(groups.allSatisfy { group in group.kinds.allSatisfy { $0.defaultFamily == group.family } })
    }

    @Test func discreetModeHidesEditedTitlesInTheHistory() async throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let entry = try journal.log(LogRequest(text: "Wrote the ACME runbook"), actor: .cli, origin: .selfReported)
        _ = try journal.entryEdit(entryID: entry.id, title: "Wrote the ACME failover runbook", kind: nil, actor: .app)
        let events = try journal.history(subject: "entry:\(entry.id)")
        let detail = LogDetail(
            entry: try journal.entry(entry.id), events: events, zone: .gmt, discreet: true, locale: Self.gb)
        #expect(detail.title == "Item 1")
        #expect(detail.versions.map(\.title) == ["Item 1", "Item 1"])
        #expect(detail.versions.map(\.what) == ["You logged it", "You changed the title"])
    }

    // MARK: links (T4.17)

    static let pr = Link(kind: .pr, url: "https://git.example.com/acme/api/pull/88")
    static let doc = Link(kind: .other, url: "https://docs.example.com/retry")

    @Test func aRowAndItsDetailCarryTheEntrysLinks() throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let entry = try journal.log(
            LogRequest(text: "Reviewed the retry fix", kind: .reviewGiven, links: [Self.pr, Self.doc]), actor: .cli, origin: .selfReported)
        let plain = try journal.log(LogRequest(text: "Wrote the ACME runbook"), actor: .cli, origin: .selfReported)
        let content = LogContent(entries: [plain, entry], today: Self.today, discreet: false, locale: Self.gb)
        let rows = content.days.flatMap(\.rows)
        #expect(rows.map(\.link?.name) == [nil, "PR #88"])
        #expect(rows.last?.link?.url == URL(string: Self.pr.url))
        #expect(rows.last?.link?.openVoice == "Open PR #88")

        let detail = LogDetail(entry: entry, events: try journal.history(subject: "entry:\(entry.id)"), zone: .gmt, discreet: false, locale: Self.gb)
        #expect(detail.links.map(\.name) == ["PR #88", "docs.example.com"])
        #expect(detail.links.map(\.link) == [Self.pr, Self.doc])
    }

    @Test func discreetModeNamesLinksByPlace() throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let entry = try journal.log(
            LogRequest(text: "Reviewed the retry fix", kind: .reviewGiven, links: [Self.pr, Self.doc]), actor: .cli, origin: .selfReported)
        let content = LogContent(entries: [entry], today: Self.today, discreet: true, locale: Self.gb)
        #expect(content.days[0].rows[0].link?.name == "Link 1")
        let detail = LogDetail(entry: entry, events: try journal.history(subject: "entry:\(entry.id)"), zone: .gmt, discreet: true, locale: Self.gb)
        #expect(detail.links.map(\.name) == ["Link 1", "Link 2"])
    }

    @Test func aLinkIsAddedFromTheDetailAndShowsInItsHistory() async throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let entry = try journal.log(LogRequest(text: "Reviewed the retry fix", kind: .reviewGiven), actor: .cli, origin: .selfReported)
        let (model, app) = try await opened(home, entry)
        model.beginAddLink()
        #expect(model.linkEdit == LinkEdit(entry: entry.id, draft: ""))
        model.setLinkDraft("  https://git.example.com/acme/api/pull/88  ")
        #expect(await model.saveLink(through: app))
        #expect(model.linkEdit == nil)
        #expect(await until { model.opened?.entry.links == [Self.pr] })
        let opened = try #require(model.opened)
        let detail = LogDetail(entry: opened.entry, events: opened.events, zone: .gmt, discreet: false, locale: Self.gb)
        #expect(detail.links.map(\.name) == ["PR #88"])
        #expect(detail.versions.map(\.what) == ["You logged it", "You changed the links"])
        // The same link again changes nothing and writes nothing.
        model.beginAddLink()
        model.setLinkDraft(Self.pr.url)
        #expect(await model.saveLink(through: app))
        #expect(try journal.history(subject: "entry:\(entry.id)").count == 2)
    }

    @Test func aRefusedLinkKeepsTheFieldAndSaysWhyInline() async throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let entry = try journal.log(LogRequest(text: "Reviewed the retry fix", kind: .reviewGiven), actor: .cli, origin: .selfReported)
        let (model, app) = try await opened(home, entry)
        model.beginAddLink()
        // Nothing typed, and not a web address: refused without asking the store.
        model.setLinkDraft("  ")
        #expect(!(await model.saveLink(through: app)))
        #expect(model.linkEdit?.problem == LinkEdit.empty)
        model.setLinkDraft("docs.example.com/retry")
        #expect(!(await model.saveLink(through: app)))
        #expect(model.linkEdit?.problem == LinkEdit.notWeb)
        // The ledger's own rule: http is refused unless the config allows its host. The reason is the rule's.
        model.setLinkDraft("http://docs.example.com/retry")
        #expect(!(await model.saveLink(through: app)))
        #expect(model.linkEdit?.draft == "http://docs.example.com/retry")
        #expect(model.linkEdit?.problem == "Only https links are accepted. Nothing was changed.")
        #expect(app.issue == nil, "the reason is shown beside the field, not as a banner too")
        // Typing again clears the reason; Esc leaves the entry as it was.
        model.setLinkDraft("https://docs.example.com/retry")
        #expect(model.linkEdit?.problem == nil)
        model.cancelAddLink()
        #expect(model.linkEdit == nil)
        #expect(try journal.history(subject: "entry:\(entry.id)").count == 1)
    }

    @Test func aSixthLinkIsRefusedWithTheRulesReason() async throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let links = (1...5).map { Link(kind: .other, url: "https://example.com/p/\($0)") }
        let entry = try journal.log(LogRequest(text: "Wrote the notes", links: links), actor: .cli, origin: .selfReported)
        let (model, app) = try await opened(home, entry)
        model.beginAddLink()
        model.setLinkDraft("https://example.com/p/6")
        #expect(!(await model.saveLink(through: app)))
        #expect(model.linkEdit?.problem == "At most 5 per entry. Nothing was changed.")
    }

    @Test func aLinkIsRemovedAsANewVersion() async throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let entry = try journal.log(
            LogRequest(text: "Reviewed the retry fix", kind: .reviewGiven, links: [Self.pr, Self.doc]), actor: .cli, origin: .selfReported)
        let (model, app) = try await opened(home, entry)
        #expect(await model.removeLink(Self.pr, through: app))
        #expect(await until { model.opened?.entry.links == [Self.doc] })
        #expect(try journal.history(subject: "entry:\(entry.id)").map(\.type) == ["entry.created", "entry.updated"])
        #expect(model.linkProblem == nil)
        // The entry in the list follows.
        #expect(await until { model.entries.first?.links == [Self.doc] })
    }

    @Test func openingAnotherEntryLeavesAnUnsavedLink() async throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        let entry = try journal.log(LogRequest(text: "Reviewed the retry fix", kind: .reviewGiven), actor: .cli, origin: .selfReported)
        let (model, _) = try await opened(home, entry)
        model.beginAddLink()
        model.setLinkDraft("https://docs.example.com/x")
        model.open(nil)
        #expect(model.linkEdit == nil)
    }

    // MARK: search from another section (section 4.8)

    @Test func searchFromAnotherSectionOpensTheLogAndLeavesASearchPending() {
        let navigation = WindowNavigation(section: .today)
        #expect(!navigation.searchPending)
        navigation.openSearch()
        #expect(navigation.section == .log)
        #expect(navigation.searchPending)
    }

    @Test func theLogTakesThePendingSearchOnce() {
        let navigation = WindowNavigation(section: .insights)
        navigation.openSearch()
        #expect(navigation.takeSearch())
        #expect(!navigation.searchPending)
        #expect(!navigation.takeSearch(), "a second look finds nothing pending")
        #expect(navigation.section == .log, "taking it leaves the Log open")
    }

    @Test func aSearchAskedForWhileTheLogIsOpenIsPendingToo() {
        let navigation = WindowNavigation(section: .log)
        navigation.openSearch()
        #expect(navigation.searchPending)
        #expect(navigation.section == .log)
    }

    @Test func aSearchNobodyTookDoesNotWaitForTheNextVisit() {
        let navigation = WindowNavigation(section: .today)
        navigation.openSearch()
        navigation.open(.recap)
        #expect(!navigation.searchPending)
        navigation.open(.log)
        #expect(!navigation.takeSearch(), "a later visit to the Log does not focus the field")
    }

    @Test func openingTheLogOnItsOwnAsksForNoSearch() {
        let navigation = WindowNavigation(section: .today)
        navigation.open(.log)
        #expect(!navigation.searchPending)
    }
}
