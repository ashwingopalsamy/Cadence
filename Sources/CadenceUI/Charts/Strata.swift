// Strata (docs/SPEC.md section 5.4, Beyond the plan): kinds of one thing stacked as layers, each as thick as its count,
// with the count and the kind printed inside. Each layer takes its kind's work colour and always carries its words.
// A kind with nothing logged has no layer.
import CadenceCore
import SwiftUI

public struct StrataFigures: ChartFigures {
    public struct Layer: Sendable, Equatable {
        public var kind: EntryKind
        public var label: String
        public var count: Int
    }

    /// The kinds that are never on a plan, in the order the layers stack, with the words each layer prints.
    public static let kinds: [(EntryKind, String)] = [
        (.meetingLed, String(localized: "Led meetings")), (.decisionChallenged, String(localized: "Challenged decisions")), (.mentoring, String(localized: "Mentored")),
        (.discussionRaised, String(localized: "Raised discussions")), (.docWritten, String(localized: "Wrote docs")), (.incidentHandled, String(localized: "Handled incidents")),
        (.initiativeStarted, String(localized: "Started initiatives")), (.initiativeProgress, String(localized: "Moved initiatives on")),
    ]

    /// Every kind, with its count; a kind with none is 0.
    public var all: [Layer]

    /// Nil when entries are unknown in the range.
    public init?(kindCounts: [String: Int]?) {
        guard let kindCounts else { return nil }
        all = Self.kinds.map { kind, label in Layer(kind: kind, label: label, count: kindCounts[kind.rawValue] ?? 0) }
    }

    public var total: Int { all.map(\.count).reduce(0, +) }

    /// The layers drawn.
    public var layers: [Layer] { all.filter { $0.count > 0 } }

    public var summary: String {
        guard total > 0 else { return String(localized: "Nothing beyond the plan was logged.") }
        return String(localized: "\(total) beyond the plan: ") + ChartText.list(layers.map { "\($0.count) \($0.label.lowercased())" }) + "."
    }

    public var table: ChartTable {
        ChartTable(columns: [String(localized: "Kind"), String(localized: "Count")], rows: layers.map { [$0.label, String($0.count)] })
    }

    /// A layer's thickness: a base that fits its words, then a fixed step per count, scaled down only when the whole
    /// stack would pass its limit. Thicker always means more.
    static func thickness(_ count: Int, layers: [Layer]) -> CGFloat {
        let base = ChartMetrics.layerBase + CadenceSpace.s4
        let room = ChartMetrics.strataMax - CGFloat(layers.count) * base
        let counts = CGFloat(layers.map(\.count).reduce(0, +))
        let unit = counts > 0 ? min(ChartMetrics.layerUnit, max(0, room) / counts) : 0
        return base + CGFloat(count) * unit
    }
}

public struct Strata: View {
    let figures: StrataFigures

    public init(_ figures: StrataFigures) {
        self.figures = figures
    }

    public var body: some View {
        VStack(spacing: ChartMetrics.layerGap) {
            ForEach(figures.layers, id: \.kind) { layer in
                HStack {
                    Text(String(layer.count)).cadenceType(ChartType.layer)
                    Spacer(minLength: CadenceSpace.s8)
                    Text(layer.label).cadenceType(ChartType.word).lineLimit(1)
                }
                .foregroundStyle(ChartColor.onAccent.color)
                .padding(.horizontal, CadenceSpace.s16)
                .frame(height: StrataFigures.thickness(layer.count, layers: figures.layers))
                .background(CadenceColor.family(layer.kind.defaultFamily).color)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.tile, style: .continuous))
        .chartAccessibility(figures.summary)
    }
}
