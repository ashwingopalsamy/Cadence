// Every dot state on one page, rendered by `make token-sheet`.
import SwiftUI

public struct DotSheet: View {
    public init() {}

    private enum Layout {
        static let width: CGFloat = 900
        static let columns = 4
        static let enlarged: CGFloat = CadenceDotTokens.glyph * 4
    }

    @Environment(\.colorScheme) private var colorScheme

    /// Each state with sample numbers from the spec's own examples.
    static let samples: [DotAppearance] = DotState.allCases.map { state in
        switch state {
        case .dayStarted:
            return DotAppearance(state: state, startedAt: Date(timeIntervalSince1970: 1_793_000_000))
        case .inProgress, .agentLogged, .wrapUpDue:
            return DotAppearance(state: state, progress: 0.6, resolved: 3, planned: 5)
        case .sealed:
            return DotAppearance(state: state, progress: 1, resolved: 5, planned: 5, streak: 19)
        case .onCall:
            return DotAppearance(state: state, onCall: true)
        default:
            return DotAppearance(state: state)
        }
    } + [DotAppearance(state: .inProgress, progress: 0.6, onCall: true, resolved: 3, planned: 5)]

    public var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s16) {
            Text("Menu-bar dot, \(colorScheme == .dark ? "dark" : "light")")
                .cadenceType(CadenceType.title)
                .foregroundStyle(CadenceColor.ink.color)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: CadenceSpace.s8), count: Layout.columns),
                alignment: .leading, spacing: CadenceSpace.s8
            ) {
                ForEach(Array(Self.samples.enumerated()), id: \.offset) { _, sample in tile(sample) }
            }
        }
        .padding(CadenceSpace.windowContent)
        .frame(width: Layout.width)
        .background(CadenceColor.canvas.color)
    }

    private func tile(_ sample: DotAppearance) -> some View {
        let image = DotRenderer.image(DotPose(sample))
        return VStack(alignment: .leading, spacing: CadenceSpace.s8) {
            HStack(alignment: .bottom, spacing: CadenceSpace.s12) {
                Image(nsImage: image).resizable().renderingMode(.template)
                    .frame(width: Layout.enlarged, height: Layout.enlarged)
                Image(nsImage: image).renderingMode(.template)
            }
            .foregroundStyle(CadenceColor.ink.color)
            Text(sample.accessibilityLabel())
                .cadenceType(CadenceType.secondary)
                .foregroundStyle(CadenceColor.ink2.color)
                .lineLimit(1)
        }
        .padding(CadenceSpace.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cadenceCard(cornerRadius: CadenceRadius.rowLarge)
    }
}
