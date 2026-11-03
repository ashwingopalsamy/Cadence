// Count tiles (docs/SPEC.md section 5.4, AI): a few small counts, each in its own tile with its words. A count that is
// unknown gets no tile, so no empty box ever stands for a target or a zero.
import CadenceCore
import SwiftUI

public struct CountTileFigures: ChartFigures {
    public struct Tile: Sendable, Equatable {
        /// What the tile prints: "19", or "2 of 4".
        public var value: String
        public var label: String
        public var family: Family

        public init(value: String, label: String, family: Family) {
            self.value = value
            self.label = label
            self.family = family
        }
    }

    public var tiles: [Tile]

    /// The tiles whose value is known. Pass nil for a count that is unknown and its tile is left out.
    public init(_ tiles: [Tile?]) {
        self.tiles = tiles.compactMap { $0 }
    }

    public var summary: String {
        guard !tiles.isEmpty else { return String(localized: "No counts recorded.") }
        return tiles.map { "\($0.label): \($0.value)" }.joined(separator: ". ") + "."
    }

    public var table: ChartTable {
        ChartTable(columns: [String(localized: "Count"), String(localized: "Value")], rows: tiles.map { [$0.label, $0.value] })
    }
}

public struct CountTiles: View {
    let figures: CountTileFigures

    public init(_ figures: CountTileFigures) {
        self.figures = figures
    }

    public var body: some View {
        HStack(spacing: CadenceSpace.s8) {
            ForEach(figures.tiles, id: \.label) { tile in
                VStack(alignment: .leading, spacing: CadenceSpace.s4) {
                    Text(tile.value)
                        .cadenceType(ChartType.tile)
                        .foregroundStyle(CadenceColor.ink.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    HStack(alignment: .firstTextBaseline, spacing: CadenceSpace.s6) {
                        RoundedRectangle(cornerRadius: CadenceSpace.s2, style: .continuous)
                            .fill(CadenceColor.family(tile.family).color)
                            .frame(width: ChartMetrics.swatch, height: ChartMetrics.swatch)
                        Text(tile.label)
                            .cadenceType(ChartType.word)
                            .foregroundStyle(CadenceColor.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(CadenceSpace.s12)
                .frame(maxWidth: .infinity, minHeight: ChartMetrics.tileHeight, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: CadenceRadius.tile, style: .continuous).fill(CadenceColor.track.color))
            }
        }
        .chartAccessibility(figures.summary)
    }
}
