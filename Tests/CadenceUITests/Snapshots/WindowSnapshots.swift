// The window's sections (docs/SPEC.md section 4.6) from the data their token sheets use: Insights, the Recap hub and
// every weekly frame, the Log with an entry open, the Inbox with proposals and empty, Proof, every Settings pane and
// every first-run step. Each fixture seeds the October ACME demo into a temporary store once for the whole run. These
// screens size themselves from their own width as they lay out, which ImageRenderer does not do, so they are drawn in a
// hosted view.
import CadenceCore
import SwiftUI
import Testing

@testable import CadenceUI

/// What the window's sections read, built once. Every fixture takes its clock and zone from the example day.
@MainActor enum SnapshotFixtures {
    static let insights: InsightsSpecimens? = InsightsSpecimens.make(in: Snapshot.scratch("insights"))
    static let recap = Result { try RecapSpecimens.seeded() }
    static let logInbox = Result { try LogInboxSpecimens.make() }
    static let proof: [ProofSpecimens.Specimen] = ProofSpecimens.make()
    static let settings = SettingsSpecimens.models(
        home: Snapshot.scratch("settings"), entitlements: Snapshot.entitlements, defaultsSuite: "cadence.snapshots.settings")
    static let firstRun = FirstRunSpecimens.models(home: Snapshot.scratch("first-run"), defaultsSuite: "cadence.snapshots.first-run")
}

@testable import CadenceUI

extension Snapshots {
    @Suite("window sections") struct WindowSections {
        private enum Layout {
            static let insights = CadenceSpace.s48 * 18 + CadenceSpace.s12
            static let hub = CGSize(width: 1000, height: 640)
            static let frame = CGSize(width: 900, height: 560)
            static let log = CGSize(width: 900, height: 720)
            static let inbox = CGSize(width: 680, height: 400)
            static let inboxEmpty = CGSize(width: 680, height: 288)
            static let proof: CGFloat = 960
            static let settings: CGFloat = 860
            static let firstRun: CGFloat = 760
        }

        // MARK: Insights

        @MainActor @Test func insightsMonth() throws {
            let fixture = try #require(SnapshotFixtures.insights, "the insights store did not seed")
            Snapshot.check("insights", "month", path: .hosting, margin: CadenceSpace.s32) {
                InsightsView(model: fixture.month, scrolls: false).frame(width: Layout.insights)
            }
        }

        @MainActor @Test func insightsTooLittleData() throws {
            let fixture = try #require(SnapshotFixtures.insights, "the insights store did not seed")
            Snapshot.check("insights", "too-little-data", path: .hosting, margin: CadenceSpace.s32) {
                InsightsView(model: fixture.forming, scrolls: false).frame(width: Layout.insights)
            }
        }

        // MARK: Recap

        /// The hub reads its recaps off the main thread, so the test waits for them to land before it draws.
        @MainActor @Test func recapHub() async throws {
            let hub = try SnapshotFixtures.recap.get()
            let model = RecapModel(loader: FixedRecaps(hub: hub))
            model.reload()
            for _ in 0..<500 where model.hub == nil { try await Task.sleep(for: .milliseconds(10)) }
            try #require(model.hub != nil, "the recap hub did not load")
            Snapshot.check("recap", "hub", path: .hosting, margin: CadenceSpace.s32) {
                RecapView(model: model)
                    .frame(width: Layout.hub.width, height: Layout.hub.height)
                    .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.card, style: .continuous))
            }
        }

        @MainActor @Test func everyWeeklyFrame() throws {
            let hub = try SnapshotFixtures.recap.get()
            #expect(!hub.weekly.frames.isEmpty)
            for index in hub.weekly.frames.indices {
                Snapshot.check("recap", "weekly-frame-\(String(format: "%02d", index + 1))", path: .hosting, margin: CadenceSpace.s32) {
                    StoryView(recap: hub.weekly, startAt: index) {}
                        .frame(width: Layout.frame.width, height: Layout.frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.card, style: .continuous))
                }
            }
        }

        // MARK: Log and Inbox

        @MainActor @Test func logWithAnEntryOpen() throws {
            let fixture = try SnapshotFixtures.logInbox.get()
            Snapshot.check("log-inbox", "log-entry-open", path: .hosting, margin: CadenceSpace.s32) {
                LogScreen(state: fixture.log, discreet: false, locale: Snapshot.locale)
                    .padding(CadenceSpace.windowContent)
                    .frame(width: Layout.log.width, height: Layout.log.height)
            }
        }

        @MainActor @Test func inboxWithProposals() throws {
            let fixture = try SnapshotFixtures.logInbox.get()
            Snapshot.check("log-inbox", "inbox-proposals", path: .hosting, margin: CadenceSpace.s32) {
                InboxScreen(state: fixture.inbox, discreet: false, showsTempo: true, locale: Snapshot.locale)
                    .padding(CadenceSpace.windowContent)
                    .frame(width: Layout.inbox.width, height: Layout.inbox.height)
            }
        }

        @MainActor @Test func inboxEmpty() throws {
            let fixture = try SnapshotFixtures.logInbox.get()
            Snapshot.check("log-inbox", "inbox-empty", path: .hosting, margin: CadenceSpace.s32) {
                InboxScreen(state: InboxScreen.Input(entries: [], today: fixture.inbox.today), discreet: false, showsTempo: true, locale: Snapshot.locale)
                    .padding(CadenceSpace.windowContent)
                    .frame(width: Layout.inboxEmpty.width, height: Layout.inboxEmpty.height)
            }
        }

        // MARK: Proof

        @MainActor @Test func proof() throws {
            let specimens = SnapshotFixtures.proof
            try #require(specimens.count == 2, "the proof fixture did not build")
            for specimen in specimens {
                Snapshot.check("proof", specimen.id, path: .hosting, margin: CadenceSpace.s32) {
                    ProofView(model: specimen.model, chooseDestination: { _ in nil }, chooseFile: { nil }).frame(width: Layout.proof)
                }
            }
        }

        // MARK: Settings and first run

        @MainActor @Test(arguments: SettingsPane.allCases) func settings(_ pane: SettingsPane) throws {
            let index = try #require(SettingsPane.allCases.firstIndex(of: pane))
            let model = SnapshotFixtures.settings[index]
            Snapshot.check("settings", Snapshot.slug(pane.title), path: .hosting, margin: CadenceSpace.s32) {
                SettingsView(model: model, showsTempo: true).frame(width: Layout.settings, alignment: .topLeading)
            }
        }

        @MainActor @Test(arguments: FirstRunStep.allCases) func firstRun(_ step: FirstRunStep) throws {
            let model = SnapshotFixtures.firstRun[step.rawValue]
            Snapshot.check("first-run", "\(step.rawValue + 1)-\(Snapshot.slug(step.title))", path: .hosting, margin: CadenceSpace.s32) {
                FirstRunView(model: model, showsTempo: true).frame(width: Layout.firstRun)
            }
        }
    }
}
