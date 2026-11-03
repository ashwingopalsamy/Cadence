import AppKit
import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// T4.6: recaps built from the October ACME demo seed, read on Sat 31 Oct at 12:00 in Asia/Kolkata, so the last
/// full week is Week 43 (19 to 25 Oct).
@Suite(.serialized) struct RecapTests {
    static let readAt = Timestamp.parse("2026-10-31T06:30:00Z")!

    /// A seeded store in a temporary home, with the demo config written beside it.
    struct Home {
        let roots: FileRoots
        let clock: ManualClock
        let journal: Journal

        init(backfillFrom: LocalDate? = nil) throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-recap-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            roots = FileRoots(home: folder)
            var config = DemoSeed.config()
            config.profile.backfillFrom = backfillFrom
            try ConfigStore.save(config, to: roots.config)
            clock = ManualClock(Timestamp.parse(DemoSeed.startInstant)!)
            let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1))
            let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
            journal = try Journal(store: store, config: config, clock: clock, ids: ids)
            try DemoSeed.seed(into: journal, clock: clock)
            clock.set(RecapTests.readAt)
        }

        func remove() { try? FileManager.default.removeItem(at: roots.home) }

        func hub(oneOnOne: LocalDate? = LocalDate("2026-10-15")) throws -> RecapHub {
            let load = RecapStoreLoader(location: .found(roots), clock: clock).load(oneOnOne: oneOnOne)
            guard case .loaded(let hub) = load else { throw CadenceError.integrity("recaps did not load: \(load)") }
            return hub
        }
    }

    @Test func weeklyIsWeek43WithFiveFramesFromTheFindings() throws {
        let home = try Home()
        defer { home.remove() }
        let week = try home.hub().weekly
        #expect(week.name == "Week 43")
        #expect(week.title == "Week 43, 19 to 23 Oct")
        #expect(week.from == LocalDate("2026-10-19")! && week.to == LocalDate("2026-10-25")!)
        #expect(week.frames.map(\.caption) == ["Week 43, 19 to 23 Oct", "The plan", "What you delivered", "Beyond the plan", "With AI"])
        #expect(week.frames.map(\.pose) == [.reviewer, .tick, .parcel, .friend, .chat])
        #expect(week.frames.map(\.deep) == [CadenceDeep.butter, CadenceDeep.blue, CadenceDeep.mint, CadenceDeep.rose, CadenceDeep.lilac])

        // Every sentence is a finding of the same range, never new wording.
        let summary = try home.journal.summary(from: week.from, to: week.to, label: "week")
        let findings = summary.findings.map(\.text)
        #expect(week.frames[0].headline == "You merged 2 PRs, reviewed 8 and raised 0 discussions.")
        #expect(findings.contains(week.frames[0].headline))
        #expect(findings.contains(week.frames[0].paragraph))
        #expect(findings.contains(week.frames[1].headline + " " + week.frames[1].paragraph))
        #expect(findings.contains(week.frames[3].headline))
        #expect(findings.contains(week.frames[4].headline + " " + week.frames[4].paragraph))

        // The plan frame carries its own water and counts every planned task once.
        let plan = week.frames[1]
        #expect(plan.headline == "92% of your plan got done.")
        #expect(plan.level == Double(summary.planDone!) / Double(summary.planTotal!))
        #expect(plan.tileCount == summary.planTotal)
        #expect(plan.tileSummary == "11 done, 1 slipped")
        #expect(week.frames[0].tileSummary == "2 merged, 8 reviewed")
    }

    @Test func thirdWeeklyFrameListsDeliveredTitlesWithSelfStartedMarked() throws {
        let home = try Home()
        defer { home.remove() }
        let frame = try home.hub().weekly.frames[2]
        #expect(frame.headline == "2 things shipped.")
        #expect(frame.delivered.count == 2)
        #expect(frame.delivered.filter(\.selfStarted).count == 1)
        let shipped = try home.journal.query(
            EntryQuery(from: LocalDate("2026-10-19")!, to: LocalDate("2026-10-25")!, kinds: [.prMerged, .shipped], statuses: [.accepted]))
        #expect(frame.delivered.map(\.title) == shipped.entries.map(\.title))
        #expect(frame.shownParagraph(discreet: false).contains(", self-started."))
        #expect(frame.shownParagraph(discreet: true) == "Item 1, self-started. Item 2.")
    }

    @Test func monthlyOneOnOneAndEarlier() throws {
        let home = try Home()
        defer { home.remove() }
        let hub = try home.hub()
        #expect(hub.monthly.title == "October so far")
        #expect(hub.monthly.frames.map(\.pose) == [.scroll, .stack, .calendar])
        #expect(hub.monthly.frames[0].headline == "84% of your plan got done.")
        #expect(hub.monthly.planPercent == 84)
        #expect(hub.oneOnOne.title == "Since your last 1:1 on 15 Oct")
        #expect(hub.oneOnOne.frames.map(\.pose) == [.twoMugs, .cards])
        #expect(hub.oneOnOneDate == LocalDate("2026-10-15")!)
        #expect(hub.earlier.map(\.name) == ["Week 42", "Week 41", "September"])
        // September is before the ledger: every figure unknown, so it has no frames and no number.
        #expect(hub.earlier[2].frames.isEmpty)
        #expect(hub.earlier[2].planPercent == nil)
    }

    @Test func cycleWaitsForAStartDateAndTheHubSaysSo() throws {
        let home = try Home()
        defer { home.remove() }
        let hub = try home.hub()
        #expect(hub.cycle == nil)
        #expect(hub.note == "Every recap copies as plain text or Markdown. A cycle recap appears once you set a cycle start date in Settings.")

        let set = try Home(backfillFrom: LocalDate("2026-10-01"))
        defer { set.remove() }
        let withCycle = try set.hub()
        #expect(withCycle.note == "Every recap copies as plain text or Markdown.")
        #expect(withCycle.cycle?.title == "Since 1 Oct")
        #expect(withCycle.cycle?.frames.map(\.pose) == [.metronome, .stamp])
    }

    @Test func unknownFiguresLeaveTheirFramesOut() throws {
        let home = try Home()
        defer { home.remove() }
        // Before the ledger began nothing is known: no frame is written, and no zero is invented.
        let september = try RecapBuilder.weekly(home.journal, monday: LocalDate("2026-09-14")!)
        #expect(september.frames.isEmpty)
        #expect(september.planPercent == nil)
        #expect(september.plainText() == "Week 38, 14 to 18 Sep\n")
        // Every frame that is written has a headline and keeps the copy rules.
        for frame in try home.hub().weekly.frames {
            #expect(!frame.headline.isEmpty)
            #expect(Findings.lint(frame.headline) && Findings.lint(frame.paragraph))
        }
    }

    @Test func copyTextIsPlainAndMarkdown() throws {
        let recap = Recap(
            kind: .weekly, name: "Week 43", title: "Week 43, 19 to 23 Oct", span: "19 to 23 Oct", from: LocalDate("2026-10-19")!,
            to: LocalDate("2026-10-25")!,
            frames: [
                RecapFrame(caption: "Week 43, 19 to 23 Oct", pose: .reviewer, headline: "You merged 4 PRs and reviewed 12.", deep: CadenceDeep.butter),
                RecapFrame(
                    caption: "The plan", pose: .tick, headline: "78% of your plan got done.", paragraph: "14 of 18 tasks.",
                    deep: CadenceDeep.blue),
                RecapFrame(
                    caption: "What you delivered", pose: .parcel, headline: "2 things shipped.",
                    delivered: [Delivered(title: "Retry budget groundwork.", selfStarted: false), Delivered(title: "Rate *limiter* tuning", selfStarted: true)],
                    deep: CadenceDeep.mint),
            ])
        #expect(
            recap.plainText() == """
                Week 43, 19 to 23 Oct

                You merged 4 PRs and reviewed 12.

                The plan
                78% of your plan got done. 14 of 18 tasks.

                What you delivered
                2 things shipped.
                - Retry budget groundwork
                - Rate *limiter* tuning, self-started

                """)
        #expect(
            recap.markdown() == """
                ## Week 43, 19 to 23 Oct

                **You merged 4 PRs and reviewed 12.**

                ### The plan

                **78% of your plan got done.** 14 of 18 tasks.

                ### What you delivered

                **2 things shipped.**

                - Retry budget groundwork
                - Rate \\*limiter\\* tuning, self-started

                """)
        #expect(recap.plainText(discreet: true).contains("- Item 2, self-started"))
        for text in [recap.plainText(), recap.markdown()] { #expect(CopyRules.allows(text)) }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cadence-recap-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        RecapCopy.write(recap, discreet: false, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == recap.plainText())
        #expect(pasteboard.string(forType: RecapCopy.markdown) == recap.markdown())
    }

    @Test func tilesAreSquareAndAPictureTooLargeIsNotDrawn() {
        func frame(_ n: Int) -> RecapFrame {
            RecapFrame(caption: "c", pose: .chat, headline: "h", tiles: [RecapTiles(.solid, n, "sessions")], deep: CadenceDeep.lilac)
        }
        #expect(frame(16).columns == 4)
        #expect(frame(19).columns == 5)
        #expect(frame(RecapTokens.maxTiles).drawsTiles)
        #expect(!frame(RecapTokens.maxTiles + 1).drawsTiles)
        #expect(!frame(0).drawsTiles)
        #expect(Findings.isoWeek(LocalDate("2026-10-19")!) == 43)
    }

    @Test @MainActor func modelPublishesWhatTheLoaderRead() async throws {
        let home = try Home()
        defer { home.remove() }
        let model = RecapModel(loader: RecapStoreLoader(location: .found(home.roots), clock: home.clock))
        model.choose(oneOnOne: LocalDate("2026-10-19")!)
        for _ in 0..<200 where model.hub == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.hub?.oneOnOne.title == "Since your last 1:1 on 19 Oct")
    }

    @Test func aMissingStoreIsAFailureNotAnEmptyRecap() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-recap-missing-\(UUID().uuidString)")
        let load = RecapStoreLoader(location: .found(FileRoots(home: folder)), clock: ManualClock(RecapTests.readAt)).load(oneOnOne: nil)
        guard case .failed(let failure) = load else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.kind == .missing)
    }
}
