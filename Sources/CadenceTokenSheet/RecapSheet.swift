// T4.6: the Recap hub and every frame of the weekly recap, built from the October ACME demo seeded into a throwaway
// store and read on Sat 31 Oct, so the last full week is Week 43. The capture waits a second, so the tiles have landed.
import CadenceCore
import CadenceUI
import Foundation
import SwiftUI

struct RecapSheet: View {
    private enum Layout {
        static let hub = CGSize(width: 1000, height: 640)
        static let frame = CGSize(width: 900, height: 560)
        static let columns = 2
    }

    let hub: RecapHub
    let model: RecapModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s24) {
            Text("Recap, hub and the weekly frames, \(colorScheme == .dark ? "dark" : "light")")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
            RecapView(model: model)
                .frame(width: Layout.hub.width, height: Layout.hub.height)
                .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.card, style: .continuous))
            Grid(alignment: .topLeading, horizontalSpacing: CadenceSpace.s24, verticalSpacing: CadenceSpace.s24) {
                ForEach(Array(stride(from: 0, to: hub.weekly.frames.count, by: Layout.columns)), id: \.self) { start in
                    GridRow {
                        ForEach(start..<min(start + Layout.columns, hub.weekly.frames.count), id: \.self) { i in
                            VStack(alignment: .leading, spacing: CadenceSpace.s8) {
                                Text("Frame \(i + 1) of \(hub.weekly.frames.count)")
                                    .cadenceType(CadenceType.label)
                                    .foregroundStyle(CadenceColor.ink3.color)
                                StoryView(recap: hub.weekly, startAt: i) {}
                                    .frame(width: Layout.frame.width, height: Layout.frame.height)
                                    .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.card, style: .continuous))
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
