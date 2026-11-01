// Space, shape and icon tokens (docs/SPEC.md section 6.4).
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
    public static let s48: CGFloat = 48

    public static let scale = [s2, s4, s6, s8, s12, s16, s20, s24, s32, s48]

    public static let pocketPadding: CGFloat = 14
    public static let sheetPadding: CGFloat = 18
    public static let windowContent: CGFloat = 22
}

public enum CadenceRadius {
    /// Also the corner of every glass surface (section 6.1).
    public static let pocket: CGFloat = 22
    public static let card: CGFloat = 16
    public static let rowLarge: CGFloat = 12
    public static let rowSmall: CGFloat = 9
    public static let mark: CGFloat = 2

    /// Inner radius = outer radius minus padding.
    public static func concentric(outer: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, outer - padding)
    }
}

public enum CadenceStroke {
    public static let hair: CGFloat = 1
}

public enum CadenceIcon {
    public static let small: CGFloat = 13
    public static let large: CGFloat = 15
    public static let weight = Font.Weight.regular
    public static let pocketWeight = Font.Weight.medium
}

extension View {
    /// Matte content card: `surface`, a `hair` rule and the resting shadow, or a ring in dark.
    public func cadenceCard(cornerRadius: CGFloat = CadenceRadius.card) -> some View {
        modifier(CardModifier(cornerRadius: cornerRadius))
    }
}

private struct CardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isLight = colorScheme == .light
        let near = isLight ? CadenceShadow.cardLight[0] : Self.none
        let far = isLight ? CadenceShadow.cardLight[1] : Self.none
        content
            .background {
                shape.fill(CadenceColor.surface.color)
                    .shadow(color: CadenceShadow.cardLightInk.opacity(near.opacity), radius: near.radius, y: near.y)
                    .shadow(color: CadenceShadow.cardLightInk.opacity(far.opacity), radius: far.radius, y: far.y)
            }
            .overlay {
                shape.strokeBorder(CadenceColor.hair.color, lineWidth: CadenceStroke.hair)
                if !isLight { shape.stroke(CadenceShadow.cardDarkRing, lineWidth: CadenceStroke.hair) }
            }
    }

    private static let none = CadenceShadow.Layer(opacity: 0, radius: 0, y: 0)
}
