// Type tokens (docs/SPEC.md section 6.3).
import AppKit
import SwiftUI

public struct TypeToken: Sendable, Identifiable {
    public enum Face: Sendable {
        case sfPro
        case geistMono
    }

    public let name: String
    public let face: Face
    public let size: CGFloat
    public let lineHeight: CGFloat
    public let weight: Int
    /// In em. SF Pro takes its tracking from the system, so only Geist Mono sets one.
    public let tracking: CGFloat
    public let sample: String

    public var id: String { name }

    public var nsFont: NSFont {
        let weight = NSFont.Weight(rawValue: Self.systemWeight(weight))
        guard face == .geistMono else { return .systemFont(ofSize: size, weight: weight) }
        guard CadenceType.isGeistMonoAvailable else { return .monospacedSystemFont(ofSize: size, weight: weight) }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: CadenceType.geistMonoFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    public var font: Font {
        let font = Font(nsFont as CTFont)
        return face == .sfPro ? font.monospacedDigit() : font
    }

    /// Maps a CSS weight to AppKit's scale. 650 sits halfway between semibold and bold.
    private static func systemWeight(_ weight: Int) -> CGFloat {
        switch weight {
        case 500: NSFont.Weight.medium.rawValue
        case 600: NSFont.Weight.semibold.rawValue
        case 650: (NSFont.Weight.semibold.rawValue + NSFont.Weight.bold.rawValue) / 2
        default: NSFont.Weight.regular.rawValue
        }
    }
}

public enum CadenceType {
    public static let geistMonoFamily = "Geist Mono"

    /// The only weight the figure roles use (section 6.3).
    public static let geistMonoFile = "GeistMono-Medium.ttf"

    /// Registers the bundled font for this process. Call once at launch, before any view renders.
    /// Without it the figure roles fall back to the system mono.
    @discardableResult
    public static func registerFonts(in directory: URL) -> Bool {
        let file = directory.appendingPathComponent(geistMonoFile) as CFURL
        return CTFontManagerRegisterFontsForURL(file, .process, nil)
    }

    public static var isGeistMonoAvailable: Bool {
        NSFontManager.shared.availableMembers(ofFontFamily: geistMonoFamily) != nil
    }

    public static let heroFigure = TypeToken(name: "hero figure", face: .geistMono, size: 34, lineHeight: 40, weight: 500, tracking: -0.03, sample: "3/5")
    public static let title = TypeToken(name: "title", face: .sfPro, size: 22, lineHeight: 28, weight: 650, tracking: 0, sample: "Thursday 29 Oct")
    public static let finding = TypeToken(name: "finding", face: .sfPro, size: 15, lineHeight: 21, weight: 600, tracking: 0, sample: "You reviewed on 18 of 19 workdays this month.")
    public static let body = TypeToken(name: "body", face: .sfPro, size: 13, lineHeight: 18, weight: 400, tracking: 0, sample: "Ship retry budget for capture path")
    public static let secondary = TypeToken(name: "secondary", face: .sfPro, size: 12, lineHeight: 16, weight: 400, tracking: 0, sample: "Merged 16:02 · ledger-core · collected")
    public static let caption = TypeToken(name: "caption, floor", face: .sfPro, size: 11, lineHeight: 14, weight: 500, tracking: 0, sample: "PLAN · FOUND TODAY")
    public static let figure = TypeToken(name: "figure", face: .geistMono, size: 13, lineHeight: 18, weight: 500, tracking: -0.01, sample: "10:02 · 6h12 · ACME-482913")

    public static let all = [heroFigure, title, finding, body, secondary, caption, figure]
}

extension View {
    /// Applies a type token, holding its line height exactly.
    public func cadenceType(_ token: TypeToken) -> some View {
        let font = token.nsFont
        // Negative when the face is taller than its token, as Geist Mono is at the hero size.
        let leading = token.lineHeight - (font.ascender - font.descender + font.leading)
        return self
            .font(token.font)
            .tracking(token.tracking * token.size)
            .lineSpacing(max(0, leading))
            .padding(.vertical, leading / 2)
    }
}
