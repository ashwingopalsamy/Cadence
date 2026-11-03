// Tempo's tokens (docs/SPEC.md sections 5.3 and 5.7). Colours and geometry come from the approved prototype, so the
// globe, its water and its props draw exactly as designed. Tempo is the same in both themes: it is an illustration.
import SwiftUI

public enum CadenceTempoTokens {
    // MARK: Colour

    /// Limbs and water, light tone.
    public static let coral = Color(tempoHex: 0xFF7A45)
    /// Limbs, shade tone. Two flat tones carry the volume; there are no outlines.
    public static let shade = Color(tempoHex: 0xE2592B)
    /// Face, metre marks, the glass edge and dark prop details.
    public static let ink = Color(tempoHex: 0x2A1710)
    /// Sun badge, bell, lock and other warm accents.
    public static let sun = Color(tempoHex: 0xF5A524)
    /// The glass itself, slightly see-through.
    public static let glass = Color.white.opacity(0.86)
    /// The inner rim, the highlight and its glint.
    public static let highlight = Color.white
    /// The three metre marks on the left of the glass.
    public static let metre = ink.opacity(0.22)
    /// The faint outer edge of the glass.
    public static let glassEdge = ink.opacity(0.2)
    /// The lit line along the water's surface.
    public static let waterSurface = Color(tempoHex: 0xFFAF85)
    public static let blush = Color(tempoHex: 0xFF5F6D)
    public static let tongue = Color(tempoHex: 0xFF8C9A)
    public static let shadow = Color.black.opacity(0.14)
    public static let badgeShadow = Color.black.opacity(0.1)
    public static let alarm = Color(tempoHex: 0xD93B30)

    /// Prop colours, flat, named for what they are.
    public enum Prop {
        public static let wood = Color(tempoHex: 0x8B5A2B)
        public static let board = Color(tempoHex: 0xB07A47)
        public static let clip = Color(tempoHex: 0x7A7A86)
        public static let rule = Color(tempoHex: 0xC9C6D2)
        public static let blue = Color(tempoHex: 0x5B93FF)
        public static let blueShade = Color(tempoHex: 0x3E76E0)
        public static let green = Color(tempoHex: 0x22C98A)
        public static let handle = Color(tempoHex: 0x5A4A3F)
        public static let lens = Color(tempoHex: 0xCFE8FF)
        public static let sandGlass = Color(tempoHex: 0xE6F1FF)
        public static let red = Color(tempoHex: 0xE5484D)
        public static let yellow = Color(tempoHex: 0xFFD95A)
        public static let ice = Color(tempoHex: 0xBDEBFF)
        public static let juice = Color(tempoHex: 0xFF9F43)
        public static let pink = Color(tempoHex: 0xFF5FA2)
        public static let lamp = Color(tempoHex: 0xFFC53D)
        public static let metal = Color(tempoHex: 0x9A9AA6)
        public static let parchment = Color(tempoHex: 0xE8E4D6)
        public static let screen = Color(tempoHex: 0x2A2A33)
        public static let cardboard = Color(tempoHex: 0xC8914F)
        public static let cardboardShade = Color(tempoHex: 0xA9743A)
        public static let cardboardLight = Color(tempoHex: 0xD9A262)
        public static let tape = Color(tempoHex: 0xF1D9B5)
        public static let quilt = Color(tempoHex: 0x8FB8FF)
    }

    /// The app icon's soft tile: a 160 degree gradient, corners at 24% of the side.
    public enum Tile {
        public static let top = Color(tempoHex: 0xFFE9DB)
        public static let bottom = Color(tempoHex: 0xFFC9AE)
        public static let angle: Double = 160
        public static let cornerFraction: CGFloat = 0.24
    }

    // MARK: Geometry, in the prototype's viewBox units

    /// The drawing's box: x from 0, y from -12, 100 wide and 124 tall.
    public static let viewBox = CGRect(x: 0, y: -12, width: 100, height: 124)
    /// The drawing may reach this far past its box on any side, as the prototype's SVG overflows visibly.
    public static let overflow: CGFloat = 24
    public static let glassCenter = CGPoint(x: 50, y: 58)
    public static let glassRadius: CGFloat = 36
    /// The water's clip, inside the rim.
    public static let waterRadius: CGFloat = 32.5
    public static let shoulderOffset: CGFloat = 33.5
    public static let shoulderY: CGFloat = 66
    public static let upperArm: CGFloat = 10.5
    public static let forearm: CGFloat = 9.5
    /// Where the face sits: eye line, and the eyes 22 apart.
    public static let eyeLine: CGFloat = 54
    /// Badges sit on a white disc at the top right.
    public static let badgeCenter = CGPoint(x: 83, y: 21)
    /// Body moves and tilt turn around the feet.
    public static let groundPivot = CGPoint(x: 50, y: 100)

    // MARK: Size, in points (the drawing's width; its height is 1.24 times that)

    public enum Size {
        public static let panel: CGFloat = 44
        public static let hero: CGFloat = 150
        public static let smallest: CGFloat = 72
        public static let largest: CGFloat = 190
        public static let sheet: CGFloat = 96
    }

    // MARK: Motion

    public enum Motion {
        /// A pose with no period of its own beats this slowly, in milliseconds.
        public static let defaultPeriod = 800
        /// The water rocks this many degrees at the top of a slosh.
        public static let sloshChoppy: Double = 14
        public static let sloshCalm: Double = 6
        public static let sloshWave: Double = 12
        /// Bubbles: each rises for 1.6 s, six times over, only on lively days and only while water is above this.
        public static let bubbleRise: TimeInterval = CadenceMotion.bubbles.duration
        public static let bubbleRises = 6
        public static let bubbleLevel: Double = 0.15
        public static let bubbleOpacity: Double = 0.85
        /// A foot lifts this far on its step; a hop lifts the whole body this far; a rock turns this many degrees.
        public static let step: CGFloat = 3
        public static let hop: CGFloat = 7
        public static let rock: Double = 4
        public static let breathe = CGSize(width: 1.025, height: 0.975)
    }

    // MARK: Composition

    /// How the day adapts the walking poses (docs/SPEC.md section 5.3). Periods are milliseconds per beat.
    public enum Pace {
        /// Above usual: 480 ms, 30 ms quicker per item over, never quicker than 340.
        public static let briskBase = 480
        public static let briskStep = 30
        public static let briskFloor = 340
        /// Below usual: 1,100 ms, 80 ms slower per item under, never slower than 1,600.
        public static let slowBase = 1100
        public static let slowStep = 80
        public static let slowCeiling = 1600
        /// In rhythm: 650 ms at noon, 10 ms slower for each hour after it.
        public static let rhythmBase = 650
        public static let rhythmNoon = 12
        public static let rhythmStep = 10
        /// One bubble per item above usual, at most this many.
        public static let bubbleCap = 3
    }

    /// The morning stretch gives way to "ponder" at this hour.
    public static let ponderHour = 11
    /// A quieter day carries a lantern from this hour.
    public static let lanternHour = 18
}

extension Color {
    /// An sRGB colour from `0xRRGGBB`.
    init(tempoHex hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255, opacity: 1
        )
    }
}
