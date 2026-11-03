// Space, shape, geometry and icon tokens (docs/SPEC.md section 6.4).
import SwiftUI

public enum CadenceSpace {
    public static let s2: CGFloat = 2
    public static let s4: CGFloat = 4
    public static let s6: CGFloat = 6
    public static let s8: CGFloat = 8
    public static let s12: CGFloat = 12
    public static let s16: CGFloat = 16
    public static let s20: CGFloat = 20
    public static let s24: CGFloat = 24
    public static let s32: CGFloat = 32
    public static let s40: CGFloat = 40
    public static let s48: CGFloat = 48

    public static let scale = [s2, s4, s6, s8, s12, s16, s20, s24, s32, s40, s48]

    public static let panelPadding: CGFloat = 16
    public static let sheetPadding: CGFloat = 24
    public static let windowContent: CGFloat = 16
}

public enum CadenceRadius {
    /// Cards, heroes, sheets, and the corner of every glass surface (section 6.1).
    public static let card: CGFloat = 24
    public static let tile: CGFloat = 16
    public static let control: CGFloat = 12
    /// Tickets, keys and other small parts.
    public static let small: CGFloat = 8

    public static let all = [card, tile, control, small]

    /// Inner radius = outer radius minus padding. Pills and buttons are `Capsule`.
    public static func concentric(outer: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, outer - padding)
    }
}

/// Fixed sizes from the geometry rules, so neighbouring parts share lines.
public enum CadenceSize {
    public static let controlPrimary: CGFloat = 40
    public static let controlSecondary: CGFloat = 32
    public static let controlToolbar: CGFloat = 28
    public static let chip: CGFloat = 24
    public static let ticket: CGFloat = 20

    public static let taskRow: CGFloat = 40
    public static let settingsRow: CGFloat = 44
    public static let foundRow: CGFloat = 36

    /// Card slots, always in this order.
    public static let labelSlot: CGFloat = 16
    public static let sentenceSlot: CGFloat = 20
    public static let numberSlot: CGFloat = 48
    public static let comparisonSlot: CGFloat = 16

    public static let panelWidth: CGFloat = 340
    public static let sheetWidth: CGFloat = 540
    public static let panelTempo: CGFloat = 44
    /// Below this the window uses its one compact layout.
    public static let compactWidth: CGFloat = 480
}

public enum CadenceStroke {
    public static let hair: CGFloat = 1
}

public enum CadenceIcon {
    public static let small: CGFloat = 13
    public static let large: CGFloat = 15
    public static let weight = Font.Weight.regular
    public static let panelWeight = Font.Weight.medium
    /// Increase Contrast thickens icon strokes by this much (section 6.7).
    static let moreStroke: CGFloat = 1.5

    /// A glyph's stroke, thicker under Increase Contrast.
    static func stroke(_ base: CGFloat, _ contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? base * moreStroke : base
    }

    /// A symbol's weight, one step heavier under Increase Contrast.
    static func weight(_ base: Font.Weight, _ contrast: ColorSchemeContrast) -> Font.Weight {
        guard contrast == .increased, let i = steps.firstIndex(of: base) else { return base }
        return steps[min(i + 1, steps.count - 1)]
    }

    private static let steps: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
}

extension View {
    /// Matte content card: `card` on `canvas`. Depth comes from colour, so there is no shadow and no border.
    public func cadenceCard(cornerRadius: CGFloat = CadenceRadius.card) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(CadenceColor.card.color)
        )
    }
}
