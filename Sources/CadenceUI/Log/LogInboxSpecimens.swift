// The Log with an entry's detail open, and the Inbox with proposals (docs/SPEC.md section 4.6), read from the ACME
// October demo seeded into a temporary store. A few synthetic entries are added on Fri 30 Oct: an agent's proposal
// that was accepted and then retitled (three versions in its history), an entry added after wrap-up, and three
// proposals from an agent, dictation and backfill, the agent's with its title being edited. Everything is ACME sample
// data. Shared by `make token-sheet` and the snapshot suite.
import CadenceCore
import Foundation

public struct LogInboxSpecimens: Sendable {
    public let log: LogScreen.Input
    public let inbox: InboxScreen.Input

    /// Seeds the demo into a temporary home, adds the sample moments, reads what the sheet shows, and removes the home.
    public static func make() throws -> LogInboxSpecimens {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-log-inbox-sheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let roots = FileRoots(home: folder)
        guard let start = Timestamp.parse(DemoSeed.startInstant), let friday = Timestamp.parse("2026-10-30T10:15:00Z") else {
            throw CadenceError.integrity("specimens: bad instants")
        }
        let clock = ManualClock(start)
        try ConfigStore.save(DemoSeed.config(), to: roots.config)
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 30))
        let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
        let journal = try Journal(store: store, config: DemoSeed.config(), clock: clock, ids: ids)
        try DemoSeed.seed(into: journal, clock: clock)

        clock.set(friday)
        let thursday = LocalDate(year: 2026, month: 10, day: 29)!
        _ = try journal.log(
            LogRequest(text: "Handled the ACME backup alert", kind: .incidentHandled, date: thursday, occurredAt: "18:40"),
            actor: .app, origin: .selfReported)
        let idea = try journal.log(
            LogRequest(text: "Started the ACME webhook replay idea", kind: .initiativeStarted, occurredAt: "15:10", proposed: true),
            actor: .mcp, origin: .agent)
        clock.set(friday.addingTimeInterval(11 * 60))
        _ = try journal.setStatus(entryID: idea.id, to: .accepted, note: nil, actor: .app)
        clock.set(friday.addingTimeInterval(14 * 60))
        _ = try journal.entryEdit(entryID: idea.id, title: "Started the ACME webhook replay plan", kind: nil, actor: .app)

        let october = LocalDate(year: 2026, month: 10, day: 5)!
        _ = try journal.log(
            LogRequest(text: "Reviewed three ACME webhook PRs", kind: .reviewGiven, date: october, proposed: true),
            actor: .cli, origin: .selfReported)
        clock.set(friday.addingTimeInterval(2 * 60 * 60))
        for request in journal.requests(fromTranscript: "Raised the ACME retry default in design review", date: nil) {
            _ = try journal.log(request, actor: .app, origin: .selfReported)
        }
        let refactor = try journal.log(
            LogRequest(text: "Refactored the ACME ledger append path", kind: .workDone, occurredAt: "15:40", proposed: true),
            actor: .mcp, origin: .agent)

        let reader = JournalReader(location: .found(roots), clock: clock)
        let read = reader.read { (journal) throws(CadenceError) -> (LogPage, Entry, [Event], [Entry]) in
            (
                try LogPage.read(journal, filter: LogFilter(), before: nil), try journal.entry(idea.id),
                try journal.history(subject: "entry:\(idea.id)"), Array(try journal.inbox().reversed())
            )
        }
        let (page, opened, events, proposals) = try read.get()
        let index = page.entries.filter { $0.day == opened.day }.firstIndex { $0.id == opened.id } ?? 0
        return LogInboxSpecimens(
            log: LogScreen.Input(
                entries: page.entries, today: page.today, zone: page.zone, hasMore: page.before != nil,
                opened: LogModel.Opened(entry: opened, events: events, index: index)),
            inbox: InboxScreen.Input(
                entries: proposals, today: page.today,
                edit: TitleEdit(entry: refactor.id, draft: "Refactored the ACME ledger append path and its tests")))
    }
}
