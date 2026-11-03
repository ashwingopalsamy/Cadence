// Type tokens (docs/SPEC.md section 6.3).
import AppKit
import SwiftUI

public struct TypeToken: Sendable, Identifiable {
    public enum Face: Sendable {
        case sfPro
        case sfRounded
        case geistMono
    }

    public let name: String
    public let face: Face
    public let size: CGFloat
    public let lineHeight: CGFloat
    public let weight: Int
    /// In em. Text roles take their tracking from the system; display roles and labels set one.
    public let tracking: CGFloat
    public let sample: String

    public var id: String { name }

    public var nsFont: NSFont {
        let weight = NSFont.Weight(rawValue: Self.systemWeight(weight))
        switch face {
        case .sfPro:
            return .systemFont(ofSize: size, weight: weight)
        case .sfRounded:
            let system = NSFont.systemFont(ofSize: size, weight: weight)
            guard let rounded = system.fontDescriptor.withDesign(.rounded) else { return system }
            return NSFont(descriptor: rounded, size: size) ?? system
        case .geistMono:
            guard CadenceType.isGeistMonoAvailable else { return .monospacedSystemFont(ofSize: size, weight: weight) }
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: CadenceType.geistMonoFamily,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            return NSFont(descriptor: descriptor, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    /// Figures are tabular in every system face.
    public var font: Font {
        let font = Font(nsFont as CTFont)
        return face == .geistMono ? font : font.monospacedDigit()
    }

    /// Maps a CSS weight to AppKit's scale.
    private static func systemWeight(_ weight: Int) -> CGFloat {
        switch weight {
        case 500: NSFont.Weight.medium.rawValue
        case 600: NSFont.Weight.semibold.rawValue
        case 700: NSFont.Weight.bold.rawValue
        case 800: NSFont.Weight.heavy.rawValue
        case 900: NSFont.Weight.black.rawValue
        default: NSFont.Weight.regular.rawValue
        }
    }
}

public enum CadenceType {
    public static let geistMonoFamily = "Geist Mono"

    /// The only weight the figure role uses (section 6.3).
    public static let geistMonoFile = "GeistMono-Medium.ttf"

    /// Registers the bundled font for this process. Call once at launch, before any view renders.
    /// Without it the figure role falls back to the system mono.
    @discardableResult
    public static func registerFonts(in directory: URL) -> Bool {
        let file = directory.appendingPathComponent(geistMonoFile) as CFURL
        return CTFontManagerRegisterFontsForURL(file, .process, nil)
    }

    public static var isGeistMonoAvailable: Bool {
        NSFontManager.shared.availableMembers(ofFontFamily: geistMonoFamily) != nil
    }

    public static let numeralLarge = TypeToken(name: "numeral, large", face: .sfRounded, size: 58, lineHeight: 60, weight: 900, tracking: -0.03, sample: "84%")
    public static let numeral = TypeToken(name: "numeral", face: .sfRounded, size: 44, lineHeight: 48, weight: 800, tracking: -0.025, sample: "3 of 5")
    public static let numeralUnit = TypeToken(name: "numeral unit", face: .sfRounded, size: 22, lineHeight: 28, weight: 800, tracking: -0.01, sample: "PRs")
    public static let answer = TypeToken(name: "answer", face: .sfRounded, size: 38, lineHeight: 44, weight: 900, tracking: -0.03, sample: "Right in your rhythm.")
    public static let section = TypeToken(name: "section", face: .sfRounded, size: 28, lineHeight: 32, weight: 900, tracking: -0.025, sample: "Steady month")
    public static let claim = TypeToken(name: "claim", face: .sfRounded, size: 22, lineHeight: 28, weight: 800, tracking: -0.018, sample: "PRs merged, and more than a quarter were your own idea.")
    public static let sentence = TypeToken(name: "sentence", face: .sfPro, size: 15, lineHeight: 20, weight: 500, tracking: 0, sample: "You have merged")
    public static let body = TypeToken(name: "body", face: .sfPro, size: 14, lineHeight: 20, weight: 400, tracking: 0, sample: "Ship retry budget for capture path")
    public static let comparison = TypeToken(name: "comparison", face: .sfPro, size: 12, lineHeight: 16, weight: 400, tracking: 0, sample: "Usually 1 or 2 a day")
    public static let label = TypeToken(name: "label, floor", face: .sfPro, size: 11, lineHeight: 16, weight: 600, tracking: 0.05, sample: "Delivery")
    public static let figure = TypeToken(name: "figure", face: .geistMono, size: 12, lineHeight: 16, weight: 500, tracking: 0, sample: "ACME-482913 · 10:02")

    public static let all = [numeralLarge, numeral, numeralUnit, answer, section, claim, sentence, body, comparison, label, figure]
}

extension View {
    /// Applies a type token, holding its line height exactly.
    public func cadenceType(_ token: TypeToken) -> some View {
        let font = token.nsFont
        // Negative when the face is taller than its token, as the heavy rounded numerals are.
        let leading = token.lineHeight - (font.ascender - font.descender + font.leading)
        return self
            .font(token.font)
            .tracking(token.tracking * token.size)
            .lineSpacing(max(0, leading))
            .padding(.vertical, leading / 2)
    }
}
