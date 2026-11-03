// Insights (docs/SPEC.md section 5.4) read from the October demo seed in a throwaway store: the month as of Thursday
// 29 October, and the same store as of Friday 9 October, when there is too little data for patterns.
import CadenceCore
import CadenceUI
import Foundation
import SwiftUI

struct InsightsSheet: View {
    private enum Layout {
        static let column = CadenceSpace.s48 * 18 + CadenceSpace.s12
    }

    let month: InsightsModel
    let forming: InsightsModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s24) {
            Text("Insights, October demo seed, \(colorScheme == .dark ? "dark" : "light")")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
            HStack(alignment: .top, spacing: CadenceSpace.s32) {
                column("Month, as of Thu 29 Oct", InsightsView(model: month, scrolls: false))
                column("Too little data, as of Fri 9 Oct", InsightsView(model: forming, scrolls: false))
            }
        }
        .padding(CadenceSpace.s48)
        .background(CadenceColor.canvas.color)
        .environment(\.locale, Locale(identifier: "en_GB"))
    }

    private func column(_ title: String, _ view: InsightsView) -> some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s8) {
            Text(title)
                .cadenceType(CadenceType.label)
                .foregroundStyle(CadenceColor.ink3.color)
            view
        }
        .frame(width: Layout.column)
    }

    /// The seed written into a fresh store under the temporary folder, read at two moments. Nil when anything fails.
    @MainActor static func make() -> InsightsSheet? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-insights-sheet", isDirectory: true)
        guard let specimens = InsightsSpecimens.make(in: folder) else { return nil }
        return InsightsSheet(month: specimens.month, forming: specimens.forming)
    }
}
