// The token sheet: every token on one page, rendered by `make token-sheet`.
import CadenceCore
import SwiftUI

public struct TokenSheet: View {
    public init() {}

    private enum Layout {
        static let width: CGFloat = 1180
        static let swatchColumns = 6
        static let swatchHeight = CadenceSpace.s48
        static let diamondAngle = 45.0
        static let diamondScale = 0.75
        static let familyMark = CadenceSpace.s12
        static let smallDot = CadenceSpace.s6
        static let barHeight = CadenceSpace.s6
        static let motionScale: CGFloat = 240
        static let curveSize = CadenceSpace.s48
        static let radiusTile = CadenceSpace.s48
    }

    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s24) {
            header
            colourSection
            HStack(alignment: .top, spacing: CadenceSpace.s32) {
                typeSection.frame(maxWidth: .infinity, alignment: .leading)
                symbolSection.frame(maxWidth: .infinity, alignment: .leading)
                shapeSection.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(CadenceSpace.windowContent)
        .frame(width: Layout.width)
        .background(CadenceColor.canvas.color)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s2) {
            Text("Design tokens, \(colorScheme == .dark ? "dark" : "light")")
                .cadenceType(CadenceType.title)
                .foregroundStyle(CadenceColor.ink.color)
            if !CadenceType.isGeistMonoAvailable {
                Text("Geist Mono is not bundled yet, so figures here use the system mono.")
                    .cadenceType(CadenceType.secondary)
                    .foregroundStyle(CadenceColor.ink2.color)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .cadenceType(CadenceType.caption)
            .foregroundStyle(CadenceColor.ink3.color)
    }

    // MARK: Colour

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s8) {
            sectionLabel("Colour")
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: CadenceSpace.s8), count: Layout.swatchColumns),
                spacing: CadenceSpace.s8
            ) {
                ForEach(CadenceColor.all) { swatch($0) }
            }
            heatStrip
        }
    }

    private func swatch(_ token: ColorToken) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(token.color).frame(height: Layout.swatchHeight)
            Rectangle().fill(CadenceColor.hair.color).frame(height: CadenceStroke.hair)
            VStack(alignment: .leading, spacing: 0) {
                Text(token.name).cadenceType(CadenceType.figure).foregroundStyle(CadenceColor.ink.color)
                Text(token.role).cadenceType(CadenceType.caption).foregroundStyle(CadenceColor.ink3.color)
                Text("\(token.light) · \(token.dark)").cadenceType(CadenceType.caption).foregroundStyle(CadenceColor.ink3.color)
            }
            .lineLimit(1)
            .padding(CadenceSpace.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.rowLarge, style: .continuous))
        .cadenceCard(cornerRadius: CadenceRadius.rowLarge)
    }

    private var heatStrip: some View {
        HStack(spacing: 0) {
            ForEach(CadenceColor.heat) { token in
                Rectangle().fill(token.color).frame(height: Layout.swatchHeight)
                    .overlay(alignment: .leading) {
                        Text(token.name)
                            .cadenceType(CadenceType.caption)
                            .foregroundStyle(heatLabelInk(token))
                            .padding(.horizontal, CadenceSpace.s8)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.rowLarge, style: .continuous))
    }

    /// The lower half of the ramp is pale in light and deep in dark; ink flips with it.
    private func heatLabelInk(_ token: ColorToken) -> Color {
        let index = CadenceColor.heat.firstIndex { $0.name == token.name } ?? 0
        return index < CadenceColor.heat.count / 2 ? CadenceColor.ink.color : CadenceColor.tipInk.color
    }

    // MARK: Type

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s12) {
            sectionLabel("Type")
            ForEach(CadenceType.all) { token in
                VStack(alignment: .leading, spacing: 0) {
                    Text(token.sample).cadenceType(token).foregroundStyle(sampleInk(token))
                    Text("\(token.name) · \(faceName(token)) \(Int(token.size))/\(Int(token.lineHeight)) · \(token.weight)")
                        .cadenceType(CadenceType.caption)
                        .foregroundStyle(CadenceColor.ink3.color)
                }
            }
        }
    }

    /// Secondary and caption samples carry their own ink, as in the Blueprint.
    private func sampleInk(_ token: TypeToken) -> Color {
        switch token.name {
        case CadenceType.secondary.name: CadenceColor.ink2.color
        case CadenceType.caption.name: CadenceColor.ink3.color
        default: CadenceColor.ink.color
        }
    }

    private func faceName(_ token: TypeToken) -> String {
        token.face == .sfPro ? "SF Pro" : CadenceType.geistMonoFamily
    }

    // MARK: Families and symbols

    private var symbolSection: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s12) {
            sectionLabel("Families, shapes, symbols")
            ForEach(Family.allCases, id: \.self) { family in
                VStack(alignment: .leading, spacing: CadenceSpace.s4) {
                    HStack(spacing: CadenceSpace.s6) {
                        familyMark(family).frame(width: Layout.familyMark, height: Layout.familyMark)
                        Text(familyName(family))
                            .cadenceType(CadenceType.secondary)
                            .foregroundStyle(CadenceColor.ink.color)
                    }
                    FlowRow(kinds: EntryKind.allCases.filter { $0.defaultFamily == family }, tint: CadenceColor.family(family).color)
                }
            }
        }
    }

    private func familyName(_ family: Family) -> String {
        switch family {
        case .delivery: "Delivery"
        case .review: "Review"
        case .initiative: "Initiative"
        case .ownership: "Ownership"
        case .leadership: "Leadership"
        case .ai: "AI"
        case .presence: "Presence and notes"
        }
    }

    @ViewBuilder
    private func familyMark(_ family: Family) -> some View {
        let tint = CadenceColor.family(family).color
        switch CadenceSymbols.shape(for: family) {
        case .circle: Circle().fill(tint)
        case .ring: Circle().strokeBorder(tint, lineWidth: CadenceSpace.s2)
        case .diamond: RoundedRectangle(cornerRadius: CadenceRadius.mark / 2).fill(tint).rotationEffect(.degrees(Layout.diamondAngle)).scaleEffect(Layout.diamondScale)
        case .square: RoundedRectangle(cornerRadius: CadenceRadius.mark).fill(tint)
        case .triangle: TriangleMark().fill(tint)
        case .smallDot: Circle().fill(tint).frame(width: Layout.smallDot, height: Layout.smallDot)
        case .none: Color.clear
        }
    }

    // MARK: Space, radii, motion

    private var shapeSection: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s16) {
            VStack(alignment: .leading, spacing: CadenceSpace.s6) {
                sectionLabel("Spacing")
                HStack(alignment: .bottom, spacing: CadenceSpace.s4) {
                    ForEach(CadenceSpace.scale, id: \.self) { step in
                        VStack(spacing: CadenceSpace.s2) {
                            Rectangle().fill(CadenceColor.accent.color).frame(width: step, height: step)
                            Text("\(Int(step))").cadenceType(CadenceType.caption).foregroundStyle(CadenceColor.ink3.color)
                        }
                    }
                }
                Text("Pocket \(Int(CadenceSpace.pocketPadding)), sheet \(Int(CadenceSpace.sheetPadding)), window \(Int(CadenceSpace.windowContent))")
                    .cadenceType(CadenceType.secondary)
                    .foregroundStyle(CadenceColor.ink2.color)
            }
            VStack(alignment: .leading, spacing: CadenceSpace.s6) {
                sectionLabel("Radii")
                HStack(spacing: CadenceSpace.s8) {
                    ForEach([CadenceRadius.pocket, CadenceRadius.card, CadenceRadius.rowLarge, CadenceRadius.rowSmall, CadenceRadius.mark], id: \.self) { radius in
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(CadenceColor.wash.color)
                            .strokeBorder(CadenceColor.hair2.color, lineWidth: CadenceStroke.hair)
                            .frame(width: Layout.radiusTile, height: Layout.radiusTile)
                            .overlay {
                                Text("\(Int(radius))").cadenceType(CadenceType.caption).foregroundStyle(CadenceColor.ink2.color)
                            }
                    }
                }
            }
            VStack(alignment: .leading, spacing: CadenceSpace.s6) {
                sectionLabel("Motion")
                HStack(alignment: .top, spacing: CadenceSpace.s12) {
                    EaseCurve()
                        .stroke(CadenceColor.accent.color, lineWidth: CadenceStroke.hair)
                        .frame(width: Layout.curveSize, height: Layout.curveSize)
                        .background(CadenceColor.wash.color)
                        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.mark))
                    VStack(alignment: .leading, spacing: CadenceSpace.s4) {
                        ForEach(CadenceMotion.all + [CadenceMotion.valueOut, CadenceMotion.valueIn]) { token in
                            HStack(spacing: CadenceSpace.s6) {
                                Rectangle().fill(CadenceColor.ink3.color)
                                    .frame(width: token.duration * Layout.motionScale, height: Layout.barHeight)
                                Text("\(token.name) \(Int((token.duration * 1000).rounded())) ms")
                                    .cadenceType(CadenceType.caption)
                                    .foregroundStyle(CadenceColor.ink2.color)
                            }
                        }
                    }
                }
                Text("Spring: response \(CadenceMotion.springResponse.formatted()), damping \(CadenceMotion.springDamping.formatted()). Value change shifts \(Int(CadenceMotion.valueChangeShift)) pt.")
                    .cadenceType(CadenceType.secondary)
                    .foregroundStyle(CadenceColor.ink2.color)
            }
        }
    }
}

private struct FlowRow: View {
    let kinds: [EntryKind]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s2) {
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: CadenceSpace.s6) {
                    HStack(spacing: CadenceSpace.s4) {
                        ForEach(symbols(for: kind), id: \.self) { symbol in
                            Image(systemName: symbol)
                                .cadenceIcon()
                                .foregroundStyle(tint)
                                .frame(width: CadenceSpace.s24)
                        }
                    }
                    Text(kind.rawValue)
                        .cadenceType(CadenceType.caption)
                        .foregroundStyle(CadenceColor.ink2.color)
                }
            }
        }
    }
}

private func symbols(for kind: EntryKind) -> [String] {
    kind == .presenceSpan ? [CadenceSymbols.dayStart, CadenceSymbols.dayEnd] : [CadenceSymbols.name(for: kind)]
}

private struct TriangleMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct EaseCurve: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CadenceMotion.ease
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.minX + c.x1 * rect.width, y: rect.maxY - c.y1 * rect.height),
            control2: CGPoint(x: rect.minX + c.x2 * rect.width, y: rect.maxY - c.y2 * rect.height)
        )
        return path
    }
}
