// Recap tokens (docs/SPEC.md sections 5.5, 5.7 and 6). Frames sit on deep editions of the colour worlds. They are
// the same in both themes: each is already dark enough, or carries dark ink, to pass 4.5:1 for text.
import SwiftUI

/// A deep frame ground and its ink.
public struct RecapDeep: Sendable, Equatable, Identifiable {
    public let name: String
    public let bg: ColorToken
    public let ink: ColorToken

    public var id: String { name }

    init(_ name: String, bg: String, ink: String) {
        self.name = name
        self.bg = ColorToken(name: "deep-\(name)", role: "Recap frame", light: bg, dark: bg)
        self.ink = ColorToken(name: "deep-\(name)-ink", role: "Recap frame text", light: ink, dark: ink)
    }

    public static func == (a: RecapDeep, b: RecapDeep) -> Bool { a.name == b.name }

    /// Night grounds take the dark control appearance, so a date field on them reads light on dark.
    public var isNight: Bool { ink.light == "#FFFFFF" }
}

public enum CadenceDeep {
    public static let butter = RecapDeep("butter", bg: "#FFC53D", ink: "#1B1500")
    public static let blue = RecapDeep("blue", bg: "#0F2A78", ink: "#FFFFFF")
    public static let mint = RecapDeep("mint", bg: "#06402E", ink: "#FFFFFF")
    public static let rose = RecapDeep("rose", bg: "#A8124A", ink: "#FFFFFF")
    public static let lilac = RecapDeep("lilac", bg: "#2A1670", ink: "#FFFFFF")

    public static let all = [butter, blue, mint, rose, lilac]
}

public enum RecapTokens {
    /// Tiles start this far apart, so they land one after another (section 5.7, 360 ms staggered).
    public static let tileStagger: TimeInterval = 0.024
    /// A tile grows from this scale as it appears.
    public static let tileFrom: CGFloat = 0.86
    /// Tile corners, as a share of the tile's side.
    public static let tileCorner: CGFloat = 0.22
    /// The outlined tile's stroke.
    public static let tileStroke: CGFloat = 2.5
    /// Faint tiles: counted, but not the thing the frame is about.
    public static let faintOpacity: Double = 0.2
    /// The faint tile's edge, in full ink, so it meets 3:1 on every deep ground and stays lighter than the outlined tile.
    public static let faintStroke: CGFloat = CadenceStroke.hair
    /// The story's focus ring, and how far outside the frame it sits.
    public static let focusRing = CadenceSpace.s2
    public static let focusGap = CadenceSpace.s4
    /// The progress bar's resting segments.
    public static let barRest: Double = 0.25
    public static let barHeight: CGFloat = CadenceSpace.s4
    /// The words take this many shares of a frame's width to the tiles' one.
    public static let wordsShare: CGFloat = 1.25
    /// A tile is never larger than this, so a frame with a few tiles keeps them small.
    public static let tileMax: CGFloat = 56
    /// The tile grid is never wider than this.
    public static let gridWidth: CGFloat = 400
    /// A frame with more tiles than this draws none, rather than a picture that is not the number.
    public static let maxTiles = 144
    public static let maxColumns = 12
    /// Tempo's width on a frame and on a hub card.
    public static let tempo: CGFloat = 92
    /// Hover wash on the story's quiet buttons: the ink at this opacity.
    public static let wash: Double = 0.14
    /// The date field's ground on a night card.
    public static let fieldWash: Double = 0.14
    /// Hub cards share one height so their numerals line up.
    public static let cardHeight: CGFloat = 208
    /// A frame shows this many delivered titles; the copy carries them all.
    public static let shownTitles = 6
    /// Below this width the frame stacks the tiles under the words (section 6.4, compact).
    public static let frameStack: CGFloat = 720
    /// The hub keeps every card on one row from this width.
    public static let hubRow: CGFloat = 820

    /// Text roles the recap adds to section 6.3, from its size list.
    public static let headline = TypeToken(name: "story headline", face: .sfRounded, size: 58, lineHeight: 60, weight: 900, tracking: -0.035, sample: "78% of your plan got done.")
    public static let headlineCompact = TypeToken(name: "story headline, compact", face: .sfRounded, size: 34, lineHeight: 40, weight: 900, tracking: -0.03, sample: "78% of your plan got done.")
    public static let paragraph = TypeToken(name: "story paragraph", face: .sfPro, size: 18, lineHeight: 24, weight: 500, tracking: 0, sample: "14 of 18 tasks.")
    public static let caption = TypeToken(name: "story caption", face: .sfPro, size: 14, lineHeight: 20, weight: 700, tracking: 0, sample: "Week 43, 19 to 23 Oct")
    public static let action = TypeToken(name: "story action", face: .sfPro, size: 14, lineHeight: 20, weight: 600, tracking: 0, sample: "Copy as text")
    public static let numeralLead = TypeToken(name: "numeral, lead card", face: .sfRounded, size: 68, lineHeight: 72, weight: 900, tracking: -0.035, sample: "78%")
    public static let unitLead = TypeToken(name: "numeral unit, lead card", face: .sfRounded, size: 28, lineHeight: 32, weight: 900, tracking: -0.02, sample: "%")
    public static let cardNote = TypeToken(name: "card note", face: .sfPro, size: 13, lineHeight: 20, weight: 500, tracking: 0, sample: "4 PRs merged and 12 reviews.")
    public static let row = TypeToken(name: "earlier row", face: .sfPro, size: 14, lineHeight: 20, weight: 600, tracking: 0, sample: "Week 42")
}
