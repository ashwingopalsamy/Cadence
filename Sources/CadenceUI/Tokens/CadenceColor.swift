// Colour tokens (docs/SPEC.md sections 4.1 and 6.2). Values come from the approved design, light then dark.
import AppKit
import CadenceCore
import SwiftUI

public struct ColorToken: Sendable, Identifiable {
    public let name: String
    public let role: String
    public let light: String
    public let dark: String
    /// Under Increase Contrast, light then dark. Nil keeps the usual value (section 6.7: hairlines strengthen).
    public var more: (light: String, dark: String)? = nil

    public var id: String { name }

    public var nsColor: NSColor {
        let light = Self.resolve(light), dark = Self.resolve(dark)
        let lightMore = more.map { Self.resolve($0.light) } ?? light, darkMore = more.map { Self.resolve($0.dark) } ?? dark
        return NSColor(name: NSColor.Name(name)) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: dark
            case .accessibilityHighContrastAqua: lightMore
            case .accessibilityHighContrastDarkAqua: darkMore
            default: light
            }
        }
    }

    public var color: Color { Color(nsColor: nsColor) }

    /// Parses `#rrggbb` or `#rrggbbaa` in sRGB.
    static func resolve(_ hex: String) -> NSColor {
        let (r, g, b, a) = channels(hex)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// The sRGB channels of `#rrggbb` or `#rrggbbaa`, each in 0...1.
    static func channels(_ hex: String) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let digits = hex.dropFirst()
        let value = UInt32(digits, radix: 16) ?? 0
        let rgba = digits.count == 8 ? value : (value << 8) | 0xff
        func channel(_ shift: UInt32) -> CGFloat { CGFloat((rgba >> shift) & 0xff) / 255 }
        return (channel(24), channel(16), channel(8), channel(0))
    }
}

public enum CadenceColor {
    public static let canvas = ColorToken(name: "canvas", role: "Window", light: "#F2F1F7", dark: "#100E17")
    public static let card = ColorToken(name: "card", role: "Cards", light: "#FFFFFF", dark: "#1C1926")
    public static let track = ColorToken(name: "track", role: "Tracks, empty states, quiet controls", light: "#EEEDF3", dark: "#2B2738")
    public static let ink = ColorToken(name: "ink", role: "Text", light: "#121116", dark: "#F7F5FB")
    public static let ink2 = ColorToken(name: "ink-2", role: "Secondary text", light: "#5B5965", dark: "#B6B3C3")
    public static let ink3 = ColorToken(name: "ink-3", role: "Labels", light: "#666470", dark: "#9794A5")
    public static let line = ColorToken(
        name: "line", role: "Rules", light: "#0000000F", dark: "#FFFFFF12", more: (light: "#00000038", dark: "#FFFFFF40"))
    public static let brand = ColorToken(name: "brand", role: "Charts about you", light: "#C4421B", dark: "#FF7A4D")
    public static let onBrand = ColorToken(name: "on-brand", role: "Text on brand", light: "#FFFFFF", dark: "#2A0E04")
    public static let focus = ColorToken(name: "focus", role: "Focus ring", light: "#2E6BFF", dark: "#8CB2FF")
    public static let good = ColorToken(name: "good", role: "Success text", light: "#0A6F47", dark: "#3EDD9F")
    public static let warn = ColorToken(name: "warn", role: "A stop in a failure card", light: "#A93206", dark: "#FF8C5A")
    public static let panel = ColorToken(name: "panel", role: "Glass under Reduce Transparency", light: "#F4F4F6DE", dark: "#232327E0")
    public static let fDelivery = ColorToken(name: "f-delivery", role: "Delivery", light: "#22C98A", dark: "#2CC98E")
    public static let fReview = ColorToken(name: "f-review", role: "Review", light: "#5B93FF", dark: "#6E9EF7")
    public static let fInitiative = ColorToken(name: "f-initiative", role: "Initiative", light: "#FF8438", dark: "#F58A47")
    public static let fOwnership = ColorToken(name: "f-ownership", role: "Ownership", light: "#FFBE16", dark: "#EDB62B")
    public static let fLeadership = ColorToken(name: "f-leadership", role: "Leadership", light: "#FF5FA2", dark: "#F26CA5")
    public static let fAI = ColorToken(name: "f-ai", role: "AI", light: "#8A66FF", dark: "#9377F2")

    public static let all: [ColorToken] = [
        canvas, card, track, ink, ink2, ink3,
        line, brand, onBrand, focus, good, warn,
        panel, fDelivery, fReview, fInitiative, fOwnership, fLeadership,
        fAI,
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

/// A colour world: the hero's ground for one group of day states. `a` and `b` are the two band tones inside it.
public struct ColorWorld: Sendable, Identifiable {
    public let name: String
    public let use: String
    public let bg: ColorToken
    public let a: ColorToken
    public let b: ColorToken
    public let ink: ColorToken

    public var id: String { name }

    /// A night world keeps its colours in dark mode; a light world is mixed this far toward black.
    public static let darkMix: CGFloat = 0.16

    public var isNight: Bool { ink.light == "#FFFFFF" }

    init(_ name: String, _ use: String, bg: String, a: String, b: String, ink: String) {
        let night = ink == "#FFFFFF"
        func token(_ part: String, _ hex: String) -> ColorToken {
            ColorToken(name: "\(name)-\(part)", role: use, light: hex, dark: night ? hex : Self.darken(hex))
        }
        self.name = name
        self.use = use
        self.bg = token("bg", bg)
        self.a = token("a", a)
        self.b = token("b", b)
        self.ink = ColorToken(name: "\(name)-ink", role: use, light: ink, dark: ink)
    }

    /// Each channel scaled toward black by `darkMix`, as the design's dark rule does.
    static func darken(_ hex: String) -> String {
        let (r, g, b, _) = ColorToken.channels(hex)
        let byte = { (c: CGFloat) in String(format: "%02X", Int((c * 255 * (1 - darkMix)).rounded())) }
        return "#" + byte(r) + byte(g) + byte(b)
    }
}

public enum CadenceWorld {
    public static let lilac = ColorWorld("lilac", "First run, first sync, still learning", bg: "#D9CCFF", a: "#C3B0FB", b: "#AE97F2", ink: "#1A1033")
    public static let butter = ColorWorld("butter", "Morning, planned", bg: "#FFD95A", a: "#F7BD1F", b: "#EBA80B", ink: "#1E1600")
    public static let coral = ColorWorld("coral", "In rhythm, more than usual", bg: "#FF9A6B", a: "#FF8250", b: "#F56C38", ink: "#25100A")
    public static let sage = ColorWorld("sage", "Fewer than usual, weekend", bg: "#BFE3CF", a: "#A0D2B7", b: "#86C2A1", ink: "#0B2418")
    public static let mint = ColorWorld("mint", "Plan settled", bg: "#7FDDB1", a: "#5FCD99", b: "#45BC84", ink: "#04241A")
    public static let rose = ColorWorld("rose", "Wrap-up due", bg: "#FFB3A8", a: "#FF978A", b: "#F5806F", ink: "#2A0D08")
    public static let forest = ColorWorld("forest", "Sealed", bg: "#0F3F3A", a: "#1C6459", b: "#26796C", ink: "#FFFFFF")
    public static let plum = ColorWorld("plum", "Yesterday open, closed unsealed", bg: "#4B2A66", a: "#62397F", b: "#75478F", ink: "#FFFFFF")
    public static let teal = ColorWorld("teal", "On call", bg: "#0F5F6B", a: "#177585", b: "#1F8797", ink: "#FFFFFF")
    public static let sky = ColorWorld("sky", "Leave, sick, holiday", bg: "#A9D3F5", a: "#90C3EE", b: "#7AB4E6", ink: "#06202F")
    public static let stone = ColorWorld("stone", "Paused, a source behind, nothing logged", bg: "#D6D7DE", a: "#C3C5CE", b: "#B1B3BE", ink: "#16171C")
    public static let ink = ColorWorld("ink", "Store problem", bg: "#26262E", a: "#35353F", b: "#43434E", ink: "#FFFFFF")

    public static let all = [lilac, butter, coral, sage, mint, rose, forest, plum, teal, sky, stone, ink]
}

/// The menu-bar accents (section 4.1): OKLCH hues at one lightness per bar, so no hue shouts louder than another.
public struct BarHue: Sendable, Identifiable {
    public enum Bar: Sendable, CaseIterable {
        case light, dark, lightMore, darkMore

        /// OKLCH lightness on this bar. The "more" bars are Increase Contrast.
        public var lightness: Double {
            switch self {
            case .light: 0.56
            case .dark: 0.80
            case .lightMore: 0.49
            case .darkMore: 0.87
            }
        }

        /// The bar the design checks contrast against.
        public var reference: String {
            switch self {
            case .light, .lightMore: "#E4E4EA"
            case .dark, .darkMore: "#27272D"
            }
        }
    }

    public let name: String
    public let hue: Double
    public let chroma: Double
    public let use: String

    public var id: String { name }

    /// sRGB channels in 0...1. Chroma steps down by 0.005 until the colour fits the gamut.
    public func rgb(on bar: Bar) -> (Double, Double, Double) {
        let l = bar.lightness
        var c = chroma
        while c >= 0 {
            let angle = hue * .pi / 180
            let (a, b) = (c * cos(angle), c * sin(angle))
            let lms = [
                pow(l + 0.3963377774 * a + 0.2158037573 * b, 3),
                pow(l - 0.1055613458 * a - 0.0638541728 * b, 3),
                pow(l - 0.0894841775 * a - 1.2914855480 * b, 3),
            ]
            let linear = [
                4.0767416621 * lms[0] - 3.3077115913 * lms[1] + 0.2309699292 * lms[2],
                -1.2684380046 * lms[0] + 2.6097574011 * lms[1] - 0.3413193965 * lms[2],
                -0.0041960863 * lms[0] - 0.7034186147 * lms[1] + 1.7076147010 * lms[2],
            ]
            if linear.allSatisfy({ $0 >= -1e-4 && $0 <= 1.0001 }) {
                let encoded = linear.map { Self.encode(min(1, max(0, $0))) }
                return (encoded[0], encoded[1], encoded[2])
            }
            c -= 0.005
        }
        return (l, l, l)
    }

    public func nsColor(on bar: Bar) -> NSColor {
        let (r, g, b) = rgb(on: bar)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func encode(_ v: Double) -> Double {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}

public enum CadenceBarColor {
    public static let coral = BarHue(name: "coral", hue: 40, chroma: 0.13, use: "In rhythm, more than usual, paused")
    public static let sage = BarHue(name: "sage", hue: 150, chroma: 0.045, use: "Fewer than usual")
    public static let blue = BarHue(name: "blue", hue: 255, chroma: 0.11, use: "Planned, not started")
    public static let green = BarHue(name: "green", hue: 170, chroma: 0.10, use: "Plan settled, sealed")
    public static let amber = BarHue(name: "amber", hue: 75, chroma: 0.13, use: "Wrap-up, morning plan, yesterday, nothing logged, a source behind")
    public static let teal = BarHue(name: "teal", hue: 210, chroma: 0.09, use: "On call")
    public static let lilac = BarHue(name: "lilac", hue: 300, chroma: 0.11, use: "First run, first sync, still learning")
    public static let rose = BarHue(name: "rose", hue: 5, chroma: 0.10, use: "Holiday")
    /// Real problems only. Never your own behaviour.
    public static let red = BarHue(name: "red", hue: 27, chroma: 0.17, use: "Store problem")

    public static let all = [coral, sage, blue, green, amber, teal, lilac, rose, red]
}

public enum CadenceShadow {
    public struct Layer: Sendable {
        public let opacity: Double
        public let radius: CGFloat
        public let y: CGFloat
    }

    /// Floating chrome only; content has no shadows. CSS blur halves to a SwiftUI radius.
    public static let floating = Layer(opacity: 0.3, radius: 28, y: 18)
}
