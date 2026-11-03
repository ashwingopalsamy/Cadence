// The Log with an entry's detail open, and the Inbox with proposals and empty (docs/SPEC.md section 4.6), drawn from
// the ACME October demo seeded into a temporary store. A few synthetic entries are added on Fri 30 Oct: an agent's
// proposal that was accepted and then retitled (three versions in its history), an entry added after wrap-up, and three
// proposals from an agent, dictation and backfill, the agent's with its title being edited. Everything is ACME sample
// data.
import CadenceCore
import CadenceUI
import Foundation
import SwiftUI

struct LogInboxSheet: View {
    private enum Layout {
        /// The window's full width (section 4.6), less nothing: the screen draws its own content edge.
        static let width: CGFloat = 900
        static let logHeight: CGFloat = 720
        /// The window's 680-point width (section 4.6).
        static let inboxWidth: CGFloat = 680
        static let inboxHeight: CGFloat = 400
        static let emptyHeight: CGFloat = 288
    }

    let log: LogScreen.Input
    let inbox: InboxScreen.Input

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s24) {
            Text("Log and Inbox, \(colorScheme == .dark ? "dark" : "light")")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
            HStack(alignment: .top, spacing: CadenceSpace.s32) {
                LogScreen(state: log, discreet: false, locale: Self.locale)
                    .padding(CadenceSpace.windowContent)
                    .frame(width: Layout.width, height: Layout.logHeight)
                VStack(alignment: .leading, spacing: CadenceSpace.s32) {
                    InboxScreen(state: inbox, discreet: false, showsTempo: true, locale: Self.locale)
                        .padding(CadenceSpace.windowContent)
                        .frame(width: Layout.inboxWidth, height: Layout.inboxHeight)
                    InboxScreen(state: InboxScreen.Input(entries: [], today: inbox.today), discreet: false, showsTempo: true, locale: Self.locale)
                        .padding(CadenceSpace.windowContent)
                        .frame(width: Layout.inboxWidth, height: Layout.emptyHeight)
                }
            }
        }
        .padding(CadenceSpace.s48)
        .background(CadenceColor.canvas.color)
    }

    static let locale = Locale(identifier: "en_GB")

    /// The sheet over the seeded demo and its sample moments.
    static func make() throws -> LogInboxSheet {
        let specimens = try LogInboxSpecimens.make()
        return LogInboxSheet(log: specimens.log, inbox: specimens.inbox)
    }
}
