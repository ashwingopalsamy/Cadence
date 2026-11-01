// Colour tokens (docs/SPEC.md section 6.2). Values come from the Blueprint, light then dark.
import AppKit
import CadenceCore
import SwiftUI

public struct ColorToken: Sendable, Identifiable {
    public let name: String
    public let role: String
    public let light: String
    public let dark: String

    public var id: String { name }

    public var nsColor: NSColor {
        let light = Self.resolve(light)
        let dark = Self.resolve(dark)
        return NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    public var color: Color { Color(nsColor: nsColor) }

    /// Parses `#rrggbb` or `#rrggbbaa` in sRGB.
    private static func resolve(_ hex: String) -> NSColor {
        let digits = hex.dropFirst()
        let value = UInt32(digits, radix: 16) ?? 0
        let rgba = digits.count == 8 ? value : (value << 8) | 0xff
        func channel(_ shift: UInt32) -> CGFloat { CGFloat((rgba >> shift) & 0xff) / 255 }
        return NSColor(srgbRed: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }
}

public enum CadenceColor {
    public static let canvas = ColorToken(name: "canvas", role: "Page and window", light: "#ffffff", dark: "#111314")
    public static let surface = ColorToken(name: "surface", role: "Cards and sheets", light: "#ffffff", dark: "#161819")
    public static let wash = ColorToken(name: "wash", role: "Insets, code, tracks", light: "#f4f5f7", dark: "#1b1e20")
    public static let wash2 = ColorToken(name: "wash-2", role: "Pressed insets", light: "#eceef1", dark: "#212527")
    public static let ink = ColorToken(name: "ink", role: "Text, done, the dot", light: "#15171a", dark: "#e9ebec")
    public static let ink2 = ColorToken(name: "ink-2", role: "Secondary text", light: "#4d535b", dark: "#a9aeb2")
    public static let ink3 = ColorToken(name: "ink-3", role: "Captions and axes", light: "#5f656d", dark: "#8a9095")
    public static let hair = ColorToken(name: "hair", role: "Rules and borders", light: "#e9ebee", dark: "#24282b")
    public static let hair2 = ColorToken(name: "hair-2", role: "Stronger rules", light: "#dadde2", dark: "#30353a")
    public static let other = ColorToken(name: "other", role: "Everything else in a chart", light: "#c8ccd2", dark: "#3d4246")
    public static let accent = ColorToken(name: "accent", role: "You and now", light: "#a556d0", dark: "#d193f6")
    public static let accentWash = ColorToken(name: "accent-wash", role: "Accent ground", light: "#a556d01a", dark: "#d193f61f")
    public static let accentLine = ColorToken(name: "accent-line", role: "Accent rule", light: "#a556d066", dark: "#d193f670")
    public static let live = ColorToken(name: "live", role: "The live indicator", light: "#548f27", dark: "#7bbb44")
    public static let fDelivery = ColorToken(name: "f-delivery", role: "Delivery", light: "#009473", dark: "#28a180")
    public static let fReview = ColorToken(name: "f-review", role: "Review", light: "#5654a2", dark: "#7271cb")
    public static let fInitiative = ColorToken(name: "f-initiative", role: "Initiative", light: "#dd4124", dark: "#e6593f")
    public static let fOwnership = ColorToken(name: "f-ownership", role: "Ownership", light: "#1a9a9f", dark: "#2aa6ab")
    public static let fLeadership = ColorToken(name: "f-leadership", role: "Leadership", light: "#b03d57", dark: "#c4506a")
    public static let fAI = ColorToken(name: "f-ai", role: "AI, neutral on purpose", light: "#5f656d", dark: "#8a9095")
    public static let tipBackground = ColorToken(name: "tip-bg", role: "Tooltip ground, inverted", light: "#15171a", dark: "#eef0f1")
    public static let tipInk = ColorToken(name: "tip-ink", role: "Tooltip text", light: "#f3f4f6", dark: "#15171a")
    public static let tipInk2 = ColorToken(name: "tip-ink-2", role: "Tooltip secondary", light: "#a9aeb5", dark: "#4d535b")
    public static let focus = ColorToken(name: "focus", role: "Focus ring", light: "#15171a", dark: "#eef0f1")

    public static let heat: [ColorToken] = [
        ColorToken(name: "heat-0", role: "Magnitude", light: "#c9e4e9", dark: "#163337"),
        ColorToken(name: "heat-1", role: "Magnitude", light: "#90bec5", dark: "#24535a"),
        ColorToken(name: "heat-2", role: "Magnitude", light: "#5fa2ac", dark: "#31717a"),
        ColorToken(name: "heat-3", role: "Magnitude", light: "#327f89", dark: "#4b919b"),
        ColorToken(name: "heat-4", role: "Magnitude", light: "#175e67", dark: "#71b0ba"),
        ColorToken(name: "heat-5", role: "Magnitude", light: "#0d3c43", dark: "#a0cfd6"),
    ]

    public static let all: [ColorToken] = [
        canvas, surface, wash, wash2, ink, ink2,
        ink3, hair, hair2, other, accent, accentWash,
        accentLine, live, fDelivery, fReview, fInitiative, fOwnership,
        fLeadership, fAI, tipBackground, tipInk, tipInk2, focus,
    ]

    public static func family(_ family: Family) -> ColorToken {
        switch family {
        case .delivery: fDelivery
        case .review: fReview
        case .initiative: fInitiative
        case .ownership: fOwnership
        case .leadership: fLeadership
        case .ai: fAI
        case .presence: ink
        }
    }
}

public enum CadenceShadow {
    public struct Layer: Sendable {
        public let opacity: Double
        public let radius: CGFloat
        public let y: CGFloat
    }

    /// The resting card shadow in light. CSS blur halves to a SwiftUI radius.
    public static let cardLight = [
        Layer(opacity: 0.04, radius: 1, y: 1),
        Layer(opacity: 0.02, radius: 0.5, y: 1),
    ]
    /// Shadow ink in light, rgb(16, 24, 40).
    public static let cardLightInk = Color(.sRGB, red: 16 / 255, green: 24 / 255, blue: 40 / 255)
    /// The resting card ring in dark, which replaces the shadow.
    public static let cardDarkRing = Color.black.opacity(0.2)
}
