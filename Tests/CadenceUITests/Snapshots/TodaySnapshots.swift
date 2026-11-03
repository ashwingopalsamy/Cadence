// Today in every day state of docs/SPEC.md section 5.2 at the window's full width (1x and 2x), then every one of them
// again at 900, 680 and the compact 420 (1x only, to bound the size of the references), on the window's canvas. The 13
// states TodaySpecimen has curated come first; the states it leaves out are the inputs TodayTests builds for each one,
// so all 23 states are drawn. Today holds a text field, so it is drawn in a hosted view.
import CadenceCore
import SwiftUI
import Testing

@testable import CadenceUI

extension Snapshots {
    @Suite("Today") struct Today {
        struct Case: Sendable, CustomTestStringConvertible {
            let name: String
            let input: TodayInput

            var testDescription: String { name }
        }

        /// The window widths of docs/SPEC.md section 4.6, content edge included.
        enum Width {
            static let full: CGFloat = 1200
            static let wide: CGFloat = 900
            static let narrow: CGFloat = 680
            static let compact: CGFloat = 420
        }

        /// A narrower window: its label is the width in the file name, as in `in-rhythm-680-light@1x.png`.
        struct Narrower: Sendable, CustomTestStringConvertible {
            let label: String
            let points: CGFloat

            var testDescription: String { label }
        }

        static let narrower = [
            Narrower(label: "900", points: Width.wide),
            Narrower(label: "680", points: Width.narrow),
            Narrower(label: "compact", points: Width.compact),
        ]

        static let cases: [Case] = {
            let curated = TodaySpecimen.all.map { Case(name: Snapshot.slug($0.name), input: $0.input) }
            let covered = Set(curated.map(\.input.state))
            let rest = DayStory.State.allCases.filter { !covered.contains($0) }.map {
                Case(name: Snapshot.slug($0.rawValue), input: TodayTests.input($0))
            }
            return curated + rest
        }()

        @MainActor static func today(_ input: TodayInput, width: CGFloat) -> some View {
            TodayContent(input: input, contentWidth: width - 2 * CadenceSpace.windowContent, actions: .none)
        }

        @MainActor @Test func everyDayStateIsDrawn() {
            #expect(Set(Self.cases.map(\.input.state)) == Set(DayStory.State.allCases))
            #expect(Set(Self.cases.map(\.name)).count == Self.cases.count, "a file name is used twice")
        }

        @MainActor @Test func theNarrowerWidthsAreDrawnInTheirOwnLayouts() {
            #expect(Self.narrower.map { TodayWidth.of($0.points) } == [.wide, .narrow, .compact])
            #expect(Set(Self.narrower.map(\.label)).count == Self.narrower.count, "a file name is used twice")
        }

        @MainActor @Test(arguments: cases) func fullWidth(_ item: Case) {
            Snapshot.check("today", "\(item.name)-full", path: .hosting, margin: CadenceSpace.windowContent) {
                Self.today(item.input, width: Width.full)
            }
        }

        @MainActor @Test(arguments: cases, narrower) func narrowerWidths(_ item: Case, _ width: Narrower) {
            Snapshot.check(
                "today", "\(item.name)-\(width.label)", path: .hosting, margin: CadenceSpace.windowContent, scales: [.one]
            ) {
                Self.today(item.input, width: width.points)
            }
        }
    }
}
