// The day ring in the cases that matter, rendered by `make token-sheet`.
import CadenceCore
import SwiftUI

public struct RingSheet: View {
    public init() {}

    private enum Layout {
        static let width: CGFloat = 1000
        static let large: CGFloat = 240
        static let compact: CGFloat = 120
        static let columns = 3
    }

    @Environment(\.colorScheme) private var colorScheme

    private static let mixed: [TaskStatus] = [.done, .done, .slipped, .dropped, .open]
    private static let day: [Family: Int] = [.delivery: 3, .review: 4, .initiative: 1, .ownership: 1, .leadership: 2, .ai: 5]
    private static let busy: [Family: Int] = [.delivery: 24, .review: 20, .initiative: 6, .ownership: 4, .leadership: 8, .ai: 9]

    public var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s16) {
            Text("Day ring, \(colorScheme == .dark ? "dark" : "light")")
                .cadenceType(CadenceType.title)
                .foregroundStyle(CadenceColor.ink.color)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CadenceSpace.s8), count: Layout.columns), spacing: CadenceSpace.s8) {
                tile("In progress", DayRingView(tasks: Self.mixed, beads: Self.day, sealed: false, size: Layout.large))
                tile("Sealed", DayRingView(tasks: [.done, .done, .done, .slipped, .dropped], beads: Self.day, sealed: true, size: Layout.large))
                tile("Nothing planned", DayRingView(tasks: [], beads: [.review: 2], sealed: false, size: Layout.large))
                tile("One task", DayRingView(tasks: [.done], beads: [.delivery: 1], sealed: false, size: Layout.large))
                tile("Every family at its limit", DayRingView(tasks: Array(repeating: .done, count: 12), beads: Self.busy, sealed: false, size: Layout.large))
                tile("Compact", DayRingView(tasks: Self.mixed, beads: Self.day, sealed: false, size: Layout.compact, style: .compact))
            }
        }
        .padding(CadenceSpace.windowContent)
        .frame(width: Layout.width)
        .background(CadenceColor.canvas.color)
    }

    private func tile(_ title: String, _ ring: DayRingView) -> some View {
        VStack(spacing: CadenceSpace.s8) {
            ring.frame(height: Layout.large, alignment: .center)
            Text(title).cadenceType(CadenceType.secondary).foregroundStyle(CadenceColor.ink2.color)
        }
        .padding(CadenceSpace.s12)
        .frame(maxWidth: .infinity)
        .cadenceCard(cornerRadius: CadenceRadius.rowLarge)
    }
}
