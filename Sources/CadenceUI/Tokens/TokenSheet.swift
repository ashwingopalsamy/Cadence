// The token sheet: every token on one page, rendered by `make token-sheet`.
import CadenceCore
import SwiftUI

public struct TokenSheet: View {
    public init() {}

    private enum Layout {
        static let width: CGFloat = 1180
        static let columns = 6
        static let swatchHeight = CadenceSpace.s48
        static let worldHeight: CGFloat = 96
        static let familyMark = CadenceSpace.s12
        static let barMark: CGFloat = 14
        static let barHeight = CadenceSpace.s6
        static let motionScale: CGFloat = 120
        static let curveSize = CadenceSpace.s48
        static let radiusTile = CadenceSpace.s48
    }

    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s24) {
            header
            colourSection
            worldSection
            barSection
            HStack(alignment: .top, spacing: CadenceSpace.s32) {
                typeSection.frame(maxWidth: .infinity, alignment: .leading)
                symbolSection.frame(maxWidth: .infinity, alignment: .leading)
                shapeSection.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(CadenceSpace.s24)
        .frame(width: Layout.width)
        .background(CadenceColor.canvas.color)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s2) {
            Text("Design tokens, \(colorScheme == .dark ? "dark" : "light")")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
            if !CadenceType.isGeistMonoAvailable {
                Text("Geist Mono is not bundled yet, so figures here use the system mono.")
                    .cadenceType(CadenceType.comparison)
                    .foregroundStyle(CadenceColor.ink2.color)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .cadenceType(CadenceType.label)
            .foregroundStyle(CadenceColor.ink3.color)
    }

    private var grid: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: CadenceSpace.s8), count: Layout.columns)
    }

    // MARK: Colour

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s8) {
            sectionLabel("Colour")
            LazyVGrid(columns: grid, spacing: CadenceSpace.s8) {
                ForEach(CadenceColor.all) { swatch($0) }
            }
        }
    }

    private func swatch(_ token: ColorToken) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(token.color).frame(height: Layout.swatchHeight)
            VStack(alignment: .leading, spacing: 0) {
                Text(token.name).cadenceType(CadenceType.figure).foregroundStyle(CadenceColor.ink.color)
                Text(token.role).cadenceType(CadenceType.comparison).foregroundStyle(CadenceColor.ink3.color)
                Text("\(token.light) · \(token.dark)").cadenceType(CadenceType.comparison).foregroundStyle(CadenceColor.ink3.color)
            }
            .lineLimit(1)
            .padding(CadenceSpace.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cadenceCard(cornerRadius: CadenceRadius.control)
        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous))
    }

    // MARK: Colour worlds

    private var worldSection: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s8) {
            sectionLabel("Colour worlds")
            LazyVGrid(columns: grid, spacing: CadenceSpace.s8) {
                ForEach(CadenceWorld.all) { world($0) }
            }
        }
    }

    private func world(_ world: ColorWorld) -> some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s2) {
            Text(world.name).cadenceType(CadenceType.claim)
            Text(world.use).cadenceType(CadenceType.comparison).lineLimit(2)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Rectangle().fill(world.a.color)
                Rectangle().fill(world.b.color)
            }
            .frame(height: Layout.barHeight)
            .clipShape(Capsule())
        }
        .foregroundStyle(world.ink.color)
        .padding(CadenceSpace.s12)
        .frame(maxWidth: .infinity, minHeight: Layout.worldHeight, alignment: .topLeading)
        .background(world.bg.color)
        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.tile, style: .continuous))
    }

    // MARK: Menu-bar palette

    private var barSection: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s8) {
            sectionLabel("Menu-bar palette, OKLCH, on the light and dark bar")
            HStack(spacing: CadenceSpace.s8) {
                bar(.light)
                bar(.dark)
            }
        }
    }

    private func bar(_ bar: BarHue.Bar) -> some View {
        HStack(spacing: CadenceSpace.s12) {
            ForEach(CadenceBarColor.all) { hue in
                VStack(spacing: CadenceSpace.s2) {
                    Circle().fill(Color(nsColor: hue.nsColor(on: bar)))
                        .frame(width: Layout.barMark, height: Layout.barMark)
                    Text(hue.name).cadenceType(CadenceType.comparison)
                }
            }
        }
        .foregroundStyle(Color(nsColor: ColorToken.resolve(bar == .light ? "#121116" : "#F7F5FB")))
        .padding(CadenceSpace.s12)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: ColorToken.resolve(bar.reference)))
        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous))
    }

    // MARK: Type

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s12) {
            sectionLabel("Type")
            ForEach(CadenceType.all) { token in
                VStack(alignment: .leading, spacing: 0) {
                    Text(token.sample).cadenceType(token).foregroundStyle(sampleInk(token)).lineLimit(1)
                    Text("\(token.name) · \(faceName(token)) \(Int(token.size))/\(Int(token.lineHeight)) · \(token.weight)")
                        .cadenceType(CadenceType.comparison)
                        .foregroundStyle(CadenceColor.ink3.color)
                }
            }
        }
    }

    /// Comparison and label samples carry their own ink, as in the design.
    private func sampleInk(_ token: TypeToken) -> Color {
        switch token.name {
        case CadenceType.comparison.name, CadenceType.label.name: CadenceColor.ink3.color
        default: CadenceColor.ink.color
        }
    }

    private func faceName(_ token: TypeToken) -> String {
        switch token.face {
        case .sfPro: "SF Pro"
        case .sfRounded: "SF Pro Rounded"
        case .geistMono: CadenceType.geistMonoFamily
        }
    }

    // MARK: Work colours and symbols

    private var symbolSection: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s12) {
            sectionLabel("Work colours and symbols")
            ForEach(Family.allCases, id: \.self) { family in
                VStack(alignment: .leading, spacing: CadenceSpace.s4) {
                    HStack(spacing: CadenceSpace.s6) {
                        Circle().fill(CadenceColor.family(family).color)
                            .frame(width: Layout.familyMark, height: Layout.familyMark)
                        Text(familyName(family))
                            .cadenceType(CadenceType.body)
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

    // MARK: Space, radii, motion

    private var shapeSection: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s16) {
            VStack(alignment: .leading, spacing: CadenceSpace.s6) {
                sectionLabel("Spacing")
                HStack(alignment: .bottom, spacing: CadenceSpace.s4) {
                    ForEach(CadenceSpace.scale, id: \.self) { step in
                        VStack(spacing: CadenceSpace.s2) {
                            Rectangle().fill(CadenceColor.brand.color).frame(width: step, height: step)
                            Text("\(Int(step))").cadenceType(CadenceType.comparison).foregroundStyle(CadenceColor.ink3.color)
                        }
                    }
                }
                Text("Panel \(Int(CadenceSpace.panelPadding)), sheet \(Int(CadenceSpace.sheetPadding)), window \(Int(CadenceSpace.windowContent))")
                    .cadenceType(CadenceType.comparison)
                    .foregroundStyle(CadenceColor.ink2.color)
            }
            VStack(alignment: .leading, spacing: CadenceSpace.s6) {
                sectionLabel("Radii")
                HStack(spacing: CadenceSpace.s8) {
                    ForEach(CadenceRadius.all, id: \.self) { radius in
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(CadenceColor.track.color)
                            .frame(width: Layout.radiusTile, height: Layout.radiusTile)
                            .overlay {
                                Text("\(Int(radius))").cadenceType(CadenceType.comparison).foregroundStyle(CadenceColor.ink2.color)
                            }
                    }
                    Capsule()
                        .fill(CadenceColor.track.color)
                        .frame(width: Layout.radiusTile, height: Layout.radiusTile / 2)
                        .overlay {
                            Text("pill").cadenceType(CadenceType.comparison).foregroundStyle(CadenceColor.ink2.color)
                        }
                }
            }
            VStack(alignment: .leading, spacing: CadenceSpace.s6) {
                sectionLabel("Motion")
                HStack(alignment: .top, spacing: CadenceSpace.s12) {
                    EaseCurve()
                        .stroke(CadenceColor.brand.color, lineWidth: CadenceStroke.hair)
                        .frame(width: Layout.curveSize, height: Layout.curveSize)
                        .background(CadenceColor.track.color)
                        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.small))
                    VStack(alignment: .leading, spacing: CadenceSpace.s4) {
                        ForEach(CadenceMotion.all) { token in
                            HStack(spacing: CadenceSpace.s6) {
                                Rectangle().fill(CadenceColor.ink3.color)
                                    .frame(width: token.duration * Layout.motionScale, height: Layout.barHeight)
                                Text("\(token.name) \(Int((token.duration * 1000).rounded())) ms\(token.curve == .spring ? ", spring" : "")")
                                    .cadenceType(CadenceType.comparison)
                                    .foregroundStyle(CadenceColor.ink2.color)
                            }
                        }
                    }
                }
                Text("Spring: response \(CadenceMotion.springResponse.formatted()), damping \(CadenceMotion.springDamping.formatted()). Attention breathes \(CadenceMotion.breaths) times; Tempo plays \(CadenceMotion.tempoBeats) beats.")
                    .cadenceType(CadenceType.comparison)
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
                        .cadenceType(CadenceType.comparison)
                        .foregroundStyle(CadenceColor.ink2.color)
                }
            }
        }
    }
}

private func symbols(for kind: EntryKind) -> [String] {
    kind == .presenceSpan ? [CadenceSymbols.dayStart, CadenceSymbols.dayEnd] : [CadenceSymbols.name(for: kind)]
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
