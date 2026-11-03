// Settings, all eight panes (docs/SPEC.md section 4.6), from an ACME config written to a throwaway folder, a fixed
// day and the entitlements file the app is signed with. Nothing here reads the real store.
import CadenceCore
import CadenceUI
import Foundation
import SwiftUI

@MainActor
struct SettingsSheet: View {
    private enum Layout {
        static let columns = 2
        static let width: CGFloat = 860
    }

    let dark: Bool
    let models: [SettingsModel]

    init(dark: Bool) {
        self.dark = dark
        models = SettingsSpecimens.models(
            home: FileManager.default.temporaryDirectory.appendingPathComponent("cadence-settings-sheet", isDirectory: true),
            entitlements: URL(fileURLWithPath: "App/Cadence.entitlements"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s24) {
            Text("Settings, all eight panes, \(dark ? "dark" : "light")")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
            Grid(alignment: .topLeading, horizontalSpacing: CadenceSpace.s48, verticalSpacing: CadenceSpace.s48) {
                ForEach(Array(stride(from: 0, to: models.count, by: Layout.columns)), id: \.self) { start in
                    GridRow(alignment: .top) {
                        ForEach(start..<min(start + Layout.columns, models.count), id: \.self) { index in
                            SettingsView(model: models[index], showsTempo: true)
                                .frame(width: Layout.width, alignment: .topLeading)
                        }
                    }
                }
            }
        }
        .padding(CadenceSpace.s48)
        .background(CadenceColor.canvas.color)
    }
}
