// First run, all six steps (docs/SPEC.md section 4.6), from an empty store with an ACME config, so GitHub offers its
// exact command and History finds a map. Each optional step is shown before its action. Nothing reads the real store.
import CadenceCore
import CadenceUI
import Foundation
import SwiftUI

@MainActor
struct FirstRunSheet: View {
    private enum Layout {
        static let columns = 2
        static let width: CGFloat = 760
    }

    let dark: Bool
    let models: [FirstRunModel]

    init(dark: Bool) {
        self.dark = dark
        models = FirstRunSpecimens.models(
            home: FileManager.default.temporaryDirectory.appendingPathComponent("cadence-firstrun-sheet", isDirectory: true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s24) {
            Text("First run, all six steps, \(dark ? "dark" : "light")")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
            Grid(alignment: .topLeading, horizontalSpacing: CadenceSpace.s32, verticalSpacing: CadenceSpace.s32) {
                ForEach(Array(stride(from: 0, to: models.count, by: Layout.columns)), id: \.self) { start in
                    GridRow(alignment: .top) {
                        ForEach(start..<min(start + Layout.columns, models.count), id: \.self) { index in
                            VStack(alignment: .leading, spacing: CadenceSpace.s8) {
                                Text("\(index + 1). \(models[index].step.title)")
                                    .cadenceType(CadenceType.label)
                                    .foregroundStyle(CadenceColor.ink3.color)
                                FirstRunView(model: models[index], showsTempo: true)
                                    .frame(width: Layout.width)
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
