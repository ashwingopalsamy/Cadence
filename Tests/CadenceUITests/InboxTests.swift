import AppKit
import CadenceCore
import Foundation
import SwiftUI
import Testing

@testable import CadenceUI

/// The Inbox (docs/SPEC.md section 4.6): accept, edit, dismiss and accept all write through `AppState`, change only the
/// status or the title, and keep the origin; empty reads "Nothing to review."
@MainActor @Suite struct InboxTests {
    typealias Home = DayStoreLoaderTests.Home

    static let gb = Locale(identifier: "en_GB")
    static let today = LocalDate("2026-09-21")!

    /// Three proposals: an agent's, a dictated line and a backfilled one. Returns their ids, oldest first.
    static func propose(_ journal: Journal) throws -> [String] {
        let agent = try journal.log(LogRequest(text: "Refactored the ACME append path", proposed: true), actor: .mcp, origin: .agent)
        let dictated = try journal.log(
            LogRequest(text: "Raised the ACME retry default", proposed: true, dictated: true), actor: .app, origin: .selfReported)
        let backfill = try journal.log(
            LogRequest(text: "Reviewed ACME webhook PRs", date: LocalDate("2026-09-04")!, proposed: true), actor: .cli,
            origin: .selfReported)
        return [agent.id, dictated.id, backfill.id]
    }

    static func make(_ home: Home) async throws -> (InboxModel, AppState, Journal, [String]) {
        let journal = try home.journal()
        let ids = try propose(journal)
        let clock = DayStoreLoaderTests.FixedClock()
        let app = AppState(
            model: DayModel(loader: home.loader),
            writer: AppWriter(location: .found(home.roots), clock: clock, poster: AppWriterTests.CountingPoster()), clock: clock)
        let inbox = InboxModel(location: .found(home.roots), clock: clock)
        inbox.start()
        #expect(await until { inbox.reads == 1 })
        return (inbox, app, journal, ids)
    }

    static func until(timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func acceptWritesTheStatusAndKeepsTheOrigin() async throws {
        let home = Home()
        defer { home.remove() }
        let (inbox, app, journal, ids) = try await Self.make(home)
        #expect(inbox.count == 3)
        #expect(await inbox.accept(ids[0], through: app))
        #expect(!inbox.entries.contains { $0.id == ids[0] })
        let accepted = try journal.entry(ids[0])
        #expect(accepted.status == .accepted)
        #expect(accepted.origin == .agent)
        let last = try #require(try journal.history(subject: "entry:\(ids[0])").last)
        #expect(last.type == "entry.status")
        #expect(last.actor == .app)
        #expect(await Self.until { inbox.reads >= 2 && inbox.entries.count == 2 })
    }

    @Test func dismissWritesTheStatusAndKeepsTheOrigin() async throws {
        let home = Home()
        defer { home.remove() }
        let (inbox, app, journal, ids) = try await Self.make(home)
        #expect(await inbox.dismiss(ids[1], through: app))
        let dismissed = try journal.entry(ids[1])
        #expect(dismissed.status == .dismissed)
        #expect(dismissed.origin == .selfReported)
        #expect(await Self.until { inbox.reads >= 2 && inbox.entries.map(\.id) == [ids[0], ids[2]] })
    }

    @Test func acceptAllAcceptsEveryProposalAndKeepsEveryOrigin() async throws {
        let home = Home()
        defer { home.remove() }
        let (inbox, app, journal, ids) = try await Self.make(home)
        let origins = try ids.map { try journal.entry($0).origin }
        #expect(await inbox.acceptAll(through: app) == 3)
        #expect(try ids.map { try journal.entry($0).status } == [.accepted, .accepted, .accepted])
        #expect(try ids.map { try journal.entry($0).origin } == origins)
        #expect(try journal.inbox().isEmpty)
        #expect(await Self.until { inbox.reads >= 2 && inbox.count == 0 })
        #expect(app.issue == nil)
    }

    @Test func aRefusedDecisionLeavesTheEntryAndSaysSo() async throws {
        let home = Home()
        defer { home.remove() }
        let (inbox, app, journal, ids) = try await Self.make(home)
        // Accepted elsewhere first: the app's own accept is refused, and the ledger is unchanged by it.
        _ = try journal.setStatus(entryID: ids[0], to: .accepted, note: nil, actor: .cli)
        let before = try journal.history(subject: "entry:\(ids[0])").count
        #expect(await !inbox.accept(ids[0], through: app))
        #expect(app.issue?.kind == .invalid)
        #expect(try journal.history(subject: "entry:\(ids[0])").count == before)
    }

    @Test func emptyReadsNothingToReview() async throws {
        let home = Home()
        defer { home.remove() }
        _ = try home.journal()
        let inbox = InboxModel(location: .found(home.roots), clock: DayStoreLoaderTests.FixedClock())
        #expect(inbox.count == nil)
        inbox.start()
        #expect(await Self.until { inbox.reads == 1 })
        #expect(inbox.phase == .loaded)
        #expect(inbox.count == 0)
        let content = InboxContent(entries: inbox.entries, today: Self.today, discreet: false, locale: Self.gb)
        #expect(content.rows.isEmpty)
        #expect(content.headline == "All clear.")
        #expect(InboxContent.emptyTitle == "Nothing to review.")
    }

    @Test func rowsSayWhyEachProposalIsHere() throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        _ = try Self.propose(journal)
        let entries = Array(try journal.inbox().reversed())
        let content = InboxContent(entries: entries, today: Self.today, discreet: false, locale: Self.gb)
        #expect(content.headline == "3 entries waiting for you.")
        #expect(content.rows.map(\.why) == ["From your dictation", "Proposed by an agent", "From the September backfill"])
        #expect(content.rows.map(\.when) == ["Today, 19:43", "Today, 19:43", "Fri 4 Sep"])
        #expect(content.rows.map(\.origin) == [.selfReported, .agent, .selfReported])
        #expect(content.rows[2].line == "Fri 4 Sep. From the September backfill.")
        #expect(
            InboxContent.footnote
                == "Proposed entries count for nothing until you accept them. Their origin never changes, even after you edit them.")

        let one = InboxContent(entries: [entries[0]], today: Self.today, discreet: true, locale: Self.gb)
        #expect(one.headline == "1 entry waiting for you.")
        #expect(one.rows.map(\.title) == ["Item 1"])
        #expect(!one.rows[0].spoken.contains("ACME"))
    }

    // MARK: editing

    @Test func editingAProposalsTitleKeepsItsOriginAndStatus() async throws {
        let home = Home()
        defer { home.remove() }
        let (inbox, app, journal, ids) = try await Self.make(home)
        inbox.beginEdit(ids[0])
        #expect(inbox.edit == TitleEdit(entry: ids[0], draft: "Refactored the ACME append path"))
        inbox.setDraft("  Refactored the ACME append path and its tests ")
        #expect(await inbox.saveEdit(through: app))
        #expect(inbox.edit == nil)
        let edited = try journal.entry(ids[0])
        #expect(edited.title == "Refactored the ACME append path and its tests")
        #expect(edited.origin == .agent)
        #expect(edited.status == .proposed)
        let history = try journal.history(subject: "entry:\(ids[0])")
        #expect(history.map(\.type) == ["entry.created", "entry.updated"])
        #expect(history.last?.actor == .app)
        #expect(await Self.until { inbox.reads >= 2 })
        #expect(inbox.entries.first { $0.id == ids[0] }?.title == "Refactored the ACME append path and its tests")
        #expect(inbox.count == 3)
        #expect(app.issue == nil)
    }

    @Test func anEmptyTitleIsRefusedAndKeepsTheField() async throws {
        let home = Home()
        defer { home.remove() }
        let (inbox, app, journal, ids) = try await Self.make(home)
        let before = try journal.history(subject: "entry:\(ids[1])").count
        inbox.beginEdit(ids[1])
        inbox.setDraft("   ")
        #expect(await !inbox.saveEdit(through: app))
        #expect(inbox.edit?.entry == ids[1])
        #expect(inbox.edit?.draft == "   ")
        #expect(inbox.edit?.problem == "A title needs a few words. Nothing was changed.")
        #expect(try journal.history(subject: "entry:\(ids[1])").count == before)
        #expect(try journal.entry(ids[1]).title == "Raised the ACME retry default")
        // Typing again clears the reason; Esc keeps the title as it was.
        inbox.setDraft("Raised")
        #expect(inbox.edit?.problem == nil)
        inbox.cancelEdit()
        #expect(inbox.edit == nil)
        #expect(try journal.history(subject: "entry:\(ids[1])").count == before)
    }

    @Test func acceptingWhileEditingSavesTheTitleFirst() async throws {
        let home = Home()
        defer { home.remove() }
        let (inbox, app, journal, ids) = try await Self.make(home)
        inbox.beginEdit(ids[2])
        inbox.setDraft("Reviewed four ACME webhook PRs")
        #expect(await inbox.accept(ids[2], through: app))
        let accepted = try journal.entry(ids[2])
        #expect(accepted.title == "Reviewed four ACME webhook PRs")
        #expect(accepted.status == .accepted)
        #expect(accepted.origin == .selfReported)
        #expect(try journal.history(subject: "entry:\(ids[2])").map(\.type) == ["entry.created", "entry.updated", "entry.status"])

        // An empty title stops the accept, so nothing is decided on words you did not mean.
        inbox.beginEdit(ids[0])
        inbox.setDraft("")
        #expect(await !inbox.accept(ids[0], through: app))
        #expect(try journal.entry(ids[0]).status == .proposed)
        #expect(inbox.edit?.problem == TitleEdit.emptyTitle)
    }

    @Test func discreetModeHidesTheFieldsWords() throws {
        let home = Home()
        defer { home.remove() }
        let journal = try home.journal()
        _ = try Self.propose(journal)
        let entries = Array(try journal.inbox().reversed())
        let edit = TitleEdit(entry: entries[0].id, draft: entries[0].title)
        for discreet in [false, true] {
            let screen = InboxScreen(
                state: InboxScreen.Input(entries: entries, today: Self.today, edit: edit), discreet: discreet, showsTempo: false,
                locale: Self.gb)
            let host = NSHostingView(rootView: screen.frame(width: 680, height: 400))
            host.frame = NSRect(x: 0, y: 0, width: 680, height: 400)
            host.layoutSubtreeIfNeeded()
            let fields = Self.textFields(in: host)
            #expect(fields.contains { $0 is NSSecureTextField } == discreet)
            if !discreet { #expect(fields.contains { $0.stringValue == entries[0].title }) }
        }
        let content = InboxContent(entries: entries, today: Self.today, discreet: true, locale: Self.gb)
        #expect(content.rows.map(\.title) == ["Item 1", "Item 2", "Item 3"])
    }

    static func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { sub -> [NSTextField] in
            let own: [NSTextField] = (sub as? NSTextField).map { [$0] } ?? []
            return own + textFields(in: sub)
        }
    }
}
