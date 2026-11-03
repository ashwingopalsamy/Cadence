// The menu-bar mark in every state of docs/SPEC.md section 4.1, drawn by MarkRenderer at the size the status item
// shows it (18 pt) on the bar's own ground, in the light and the dark bar, at 1x and 2x. One file per state, so a
// single wrong mark fails on its own.
import AppKit
import CadenceCore
import SwiftUI
import Testing

@testable import CadenceUI

extension Snapshots {
    @Suite("the menu-bar mark") struct Marks {
        /// The mark on a chip of the bar's reference colour: the light theme is the light bar, the dark theme the dark bar.
        private struct MarkChip: View {
            let form: MarkForm
            @Environment(\.colorScheme) private var scheme

            var body: some View {
                let bar = MarkBar(appearance: NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!, increaseContrast: false)
                Image(nsImage: MarkRenderer.image(form, bar: bar))
                    .frame(width: CadenceMarkTokens.side + CadenceSpace.s16, height: CadenceMarkTokens.side + CadenceSpace.s8)
                    .background(Color(nsColor: ColorToken.resolve(bar.palette.reference)))
            }
        }

        @MainActor @Test func everyDayStateHasAMark() {
            #expect(Set(MarkSpecimen.all.compactMap(\.state)) == Set(DayStory.State.allCases))
            #expect(MarkSpecimen.all.contains { $0.state == nil }, "discreet mode has its own mark")
        }

        @MainActor @Test(arguments: MarkSpecimen.all.map { Named(name: $0.name, value: $0) }) func mark(_ item: Named<MarkSpecimen>) {
            Snapshot.check("marks", Snapshot.slug(item.name), margin: 0) { MarkChip(form: item.value.form) }
        }
    }
}
