// Slip reasons (docs/SPEC.md section 5.4, Slipped): one bar per reason, largest first, the count printed inside and the
// reason under it. Only the fixed chips are named; a typed reason reads "For another reason", so free text never
// reaches the chart (docs/decisions/README.md, T4.5).
import CadenceCore
import SwiftUI

public struct SlipFigures: ChartFigures {
    public struct Reason: Sendable, Equatable {
        public var label: String
        public var count: Int
    }

    /// Reasons with at least one slip, largest first, then by label.
    public var reasons: [Reason]

    /// Nil when the range has no plan, so slips are unknown.
    public init?(slipsByReason: [String: Int]?) {
        guard let slipsByReason else { return nil }
        var counts: [String: Int] = [:]
        for (stored, n) in slipsByReason where n > 0 {
            counts[Self.label(stored), default: 0] += n
        }
        reasons = counts.map { Reason(label: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }

    /// A stored reason as the chart names it.
    static func label(_ stored: String) -> String {
        if stored == "unspecified" { return String(localized: "No reason given") }
        return SlipReason(stored: stored)?.label ?? String(localized: "For another reason")
    }

    /// A reason as it reads after its count: "2 blocked", "1 with no reason".
    static func phrase(_ label: String) -> String { label == String(localized: "No reason given") ? String(localized: "with no reason") : label.lowercased() }

    public var total: Int { reasons.map(\.count).reduce(0, +) }

    public var summary: String {
        guard total > 0 else { return String(localized: "None slipped.") }
        return String(localized: "\(total) slipped: ") + ChartText.list(reasons.map { "\($0.count) \(Self.phrase($0.label))" }) + "."
    }

    public var table: ChartTable {
        ChartTable(columns: [String(localized: "Reason"), String(localized: "Slips")], rows: reasons.map { [$0.label, String($0.count)] })
    }
}

public struct SlipReasons: View {
    let figures: SlipFigures

    public init(_ figures: SlipFigures) {
        self.figures = figures
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s4) {
            ForEach(Array(figures.reasons.enumerated()), id: \.element.label) { index, reason in
                bar(reason, index: index)
                Text(reason.label)
                    .cadenceType(ChartType.hint)
                    .foregroundStyle(CadenceColor.ink3.color)
                    .padding(.bottom, CadenceSpace.s4)
            }
        }
        .chartAccessibility(figures.summary)
    }

    private func bar(_ reason: SlipFigures.Reason, index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
        let top = max(1, figures.reasons.first?.count ?? 1)
        let mix = ChartMetrics.zoneMix[min(index, ChartMetrics.zoneMix.count - 1)]
        return GeometryReader { proxy in
            Text(String(reason.count))
                .cadenceType(ChartType.word)
                .foregroundStyle((index == 0 ? CadenceColor.onBrand : ChartColor.onAccent).color)
                .padding(.leading, CadenceSpace.s8)
                .frame(
                    width: max(ChartMetrics.zoneMin, proxy.size.width * CGFloat(reason.count) / CGFloat(top)),
                    height: proxy.size.height, alignment: .leading
                )
                .background(shape.fill(CadenceColor.brand.color.opacity(mix)))
        }
        .frame(height: ChartMetrics.zone)
        .background(shape.fill(CadenceColor.track.color))
    }
}
