// The menu-bar panel in every state of its table (docs/SPEC.md section 4.2), drawn from sample data with ACME
// titles only. Shown on the solid Reduce Transparency ground, since a capture has nothing behind the glass.
import CadenceCore
import CadenceUI
import SwiftUI

struct PanelSheet: View {
    private enum Layout {
        static let columns = 4
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s24) {
            Text("Menu-bar panel, every state, \(colorScheme == .dark ? "dark" : "light")")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
            Grid(alignment: .topLeading, horizontalSpacing: CadenceSpace.s32, verticalSpacing: CadenceSpace.s32) {
                ForEach(Array(stride(from: 0, to: PanelSpecimens.samples.count, by: Layout.columns)), id: \.self) { start in
                    GridRow(alignment: .top) {
                        ForEach(PanelSpecimens.samples[start..<min(start + Layout.columns, PanelSpecimens.samples.count)], id: \.name) { sample in
                            VStack(alignment: .leading, spacing: CadenceSpace.s8) {
                                Text(sample.name)
                                    .cadenceType(CadenceType.label)
                                    .foregroundStyle(CadenceColor.ink3.color)
                                PanelCard(content: PanelContent(sample.input, locale: Locale(identifier: "en_GB")), solid: true)
                                    .shadow(
                                        color: .black.opacity(CadenceShadow.floating.opacity), radius: CadenceShadow.floating.radius,
                                        y: CadenceShadow.floating.y)
                            }
                        }
                    }
                }
            }
        }
        .padding(CadenceSpace.s48)
        .background(CadenceColor.canvas.color)
    }
}
