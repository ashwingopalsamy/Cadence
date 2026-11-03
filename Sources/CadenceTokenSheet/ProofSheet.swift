// The Proof section (docs/SPEC.md sections 4.6 and 12) against the October demo: the file exported and checked,
// and a hand-edited file that fails Check a file. The demo is seeded into a temporary home that is removed once the
// states are read, and every file goes to that home, never into the repository.
import CadenceCore
import CadenceUI
import Foundation
import SwiftUI

@MainActor
struct ProofSheet: View {
    private enum Layout {
        /// The window's full width, where the four cards sit two by two.
        static let width: CGFloat = 960
    }

    let dark: Bool
    let specimens: [ProofSpecimens.Specimen]

    init(dark: Bool) {
        self.dark = dark
        specimens = ProofSpecimens.make()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s8) {
            Text("Proof, \(dark ? "dark" : "light")")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
            ForEach(specimens) { specimen in
                Text(specimen.title)
                    .cadenceType(CadenceType.label)
                    .foregroundStyle(CadenceColor.ink3.color)
                    .padding(.top, CadenceSpace.s24)
                ProofView(model: specimen.model, chooseDestination: { _ in nil }, chooseFile: { nil })
                    .frame(width: Layout.width)
            }
        }
        .padding(CadenceSpace.s48)
        .background(CadenceColor.canvas.color)
        .environment(\.locale, Locale(identifier: "en_GB"))
    }
}
