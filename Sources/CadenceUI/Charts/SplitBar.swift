// The split bar (docs/SPEC.md section 5.4, Delivery): merged PRs as assigned, self-started and no ticket, each part as
// wide as its count and labelled inside. A part with no PRs is left out, so no empty box stands for a target.
import CadenceCore
import SwiftUI

public struct SplitFigures: ChartFigures {
    public struct Part: Sendable, Equatable {
        public var label: String
        public var count: Int
        public var hue: ChartHue?
    }

    public var assigned: Int
    public var selfStarted: Int
    public var noTicket: Int

    /// Nil when the merged count or its split is unknown: there is nothing to draw.
    public init?(merged: Int?, assigned: Int?, selfStarted: Int?) {
        guard let merged, let assigned, let selfStarted, merged >= assigned + selfStarted else { return nil }
        self.assigned = assigned
        self.selfStarted = selfStarted
        self.noTicket = merged - assigned - selfStarted
    }

    public var merged: Int { assigned + selfStarted + noTicket }

    /// Every part, in the fixed order, with its count.
    public var all: [Part] {
        [
            Part(label: String(localized: "Assigned"), count: assigned, hue: .family(.delivery)),
            Part(label: String(localized: "Self-started"), count: selfStarted, hue: .family(.initiative)),
            Part(label: String(localized: "No ticket"), count: noTicket, hue: nil),
        ]
    }

    /// The parts drawn: those with at least one PR.
    public var parts: [Part] { all.filter { $0.count > 0 } }

    public var summary: String {
        guard merged > 0 else { return String(localized: "No PRs merged.") }
        return String(localized: "\(ChartText.count(merged, String(localized: "PR"))) merged: \(assigned) assigned, \(selfStarted) self-started, \(noTicket) with no ticket.")
    }

    public var table: ChartTable {
        ChartTable(columns: [String(localized: "Ticket"), String(localized: "Merged PRs")], rows: all.map { [$0.label, String($0.count)] })
    }
}

public struct SplitBar: View {
    let figures: SplitFigures

    public init(_ figures: SplitFigures) {
        self.figures = figures
    }

    public var body: some View {
        ProportionalRow(spacing: ChartMetrics.splitGap) {
            ForEach(figures.parts, id: \.label) { part in
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    Text(String(part.count)).cadenceType(ChartType.inside)
                    Text(part.label).cadenceType(ChartType.word).lineLimit(1).fixedSize()
                }
                .foregroundStyle((part.hue?.onFill ?? CadenceColor.ink).color)
                .padding(.horizontal, CadenceSpace.s12)
                .padding(.vertical, CadenceSpace.s8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background((part.hue?.token ?? CadenceColor.track).color)
                .layoutValue(key: ProportionalWeight.self, value: CGFloat(part.count))
            }
        }
        .frame(height: ChartMetrics.split)
        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.tile, style: .continuous))
        .chartAccessibility(figures.summary)
    }
}

struct ProportionalWeight: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

/// Lays children side by side, each as wide as its weight's share of the row and never narrower than its content.
/// A child that would be too narrow keeps its own width, and the rest share what is left by weight.
struct ProportionalRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? ideal.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        let height = proposal.height ?? ideal.map(\.height).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = Self.widths(
            minimums: subviews.map { $0.sizeThatFits(.unspecified).width }, weights: subviews.map { $0[ProportionalWeight.self] },
            total: bounds.width - spacing * CGFloat(max(0, subviews.count - 1)))
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    /// Shares `total` by weight, holding every child at least at its minimum.
    static func widths(minimums: [CGFloat], weights: [CGFloat], total: CGFloat) -> [CGFloat] {
        var fixed = Array(repeating: false, count: minimums.count)
        var widths = Array(repeating: CGFloat(0), count: minimums.count)
        while true {
            let free = total - zip(widths, fixed).filter(\.1).map(\.0).reduce(0, +)
            let weight = zip(weights, fixed).filter { !$0.1 }.map(\.0).reduce(0, +)
            var changed = false
            for i in minimums.indices where !fixed[i] {
                let share = weight > 0 ? free * weights[i] / weight : 0
                if share < minimums[i] {
                    widths[i] = minimums[i]
                    fixed[i] = true
                    changed = true
                }
            }
            if !changed {
                for i in minimums.indices where !fixed[i] { widths[i] = weight > 0 ? free * weights[i] / weight : 0 }
                return widths
            }
        }
    }
}
