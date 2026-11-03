// The morning plan sheet and every step of the wrap-up (docs/SPEC.md sections 4.4 and 4.5), today's and yesterday's,
// then the sealing end state, on the solid sheet ground a render has to use. The morning plan holds a text field, so it
// is drawn in a hosted view; the rest are drawn by ImageRenderer.
import SwiftUI
import Testing

@testable import CadenceUI

extension Snapshots {
    @Suite("sheets") struct Sheets {
        struct WrapCase: Sendable, CustomTestStringConvertible {
            let name: String
            let step: WrapUpStep
            var yesterday = false
            var counts: [WrapUpSignal: Int] = [:]
            var showsStandup = false

            var testDescription: String { name }
        }

        /// The wrap-up in each step, as the sheet gallery shows them.
        static let wrapUps = [
            WrapCase(name: "wrap-up-task", step: .task(0)),
            WrapCase(name: "wrap-up-reason", step: .reason(0)),
            WrapCase(name: "wrap-up-signals", step: .signals, counts: [.meetingLed: 1, .mentored: 2]),
            WrapCase(name: "wrap-up-ready", step: .ready, showsStandup: true),
        ]

        /// The wrap-up of yesterday, which names the weekday in its title, its Move button and its Seal button.
        static let yesterdays = [
            WrapCase(name: "wrap-up-yesterday-task", step: .task(1), yesterday: true),
            WrapCase(name: "wrap-up-yesterday-ready", step: .ready, yesterday: true),
        ]

        /// `WrapUpFlow` writes those weekdays in the system language, and nothing a view's environment sets reaches it.
        /// On a Mac set to another language they would read in that language, so the two specimens wait for an English one.
        static let englishSystem = Locale.current.language.languageCode?.identifier == "en"

        /// A sheet on the solid ground, without the shadow its window gives it.
        @MainActor private static func solid<V: View>(_ sheet: V) -> some View {
            sheet.environment(\.sheetSurface, .solid)
        }

        @MainActor @Test func morningPlan() {
            Snapshot.check("sheets", "morning-plan", path: .hosting, margin: CadenceSpace.s24) {
                Self.solid(PlanSheet(model: SheetSpecimens.plan, titles: SheetTitles(), onStart: {}, onLater: {}, onDayOff: { _ in }))
            }
        }

        @MainActor @Test(arguments: wrapUps) func wrapUp(_ item: WrapCase) { Self.check(item) }

        @MainActor @Test(
            .enabled(if: englishSystem, "the weekday in these labels is written in the system language, which is not English"),
            arguments: yesterdays)
        func wrapUpOfYesterday(_ item: WrapCase) { Self.check(item) }

        @MainActor private static func check(_ item: WrapCase) {
            Snapshot.check("sheets", item.name, margin: CadenceSpace.s24) {
                let flow = SheetSpecimens.wrap(
                    item.step, yesterday: item.yesterday, counts: item.counts, preview: item.showsStandup ? SheetSpecimens.standup : nil)
                return Self.solid(SheetSpecimens.wrapSheet(flow))
            }
        }

        @MainActor @Test func sealing() {
            Snapshot.check("sheets", "sealing", margin: CadenceSpace.s24) {
                Self.solid(
                    SealingView(tempo: nil, showsTempo: true, settled: true)
                        .frame(width: SheetLayout.width, height: SealingView.specimenHeight)
                        .clipShape(RoundedRectangle(cornerRadius: SheetLayout.radius, style: .continuous)))
            }
        }
    }
}
