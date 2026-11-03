import CadenceCore
import Foundation
import SwiftUI
import Testing

@testable import CadenceUI

@Suite struct TokenTests {
    /// WCAG 2 relative luminance of sRGB channels in 0...1.
    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func luminance(_ hex: String) -> Double {
        let (r, g, b, _) = ColorToken.channels(hex)
        return luminance(Double(r), Double(g), Double(b))
    }

    static func contrast(_ x: Double, _ y: Double) -> Double {
        (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test func everyWorldPassesInItsWorstTheme() {
        for world in CadenceWorld.all {
            let ink = Self.luminance(world.ink.light)
            for hex in [world.bg.light, world.bg.dark] {
                #expect(Self.contrast(ink, Self.luminance(hex)) >= 4.5, "\(world.name) text on \(hex)")
            }
            for hex in [world.b.light, world.b.dark] {
                #expect(Self.contrast(ink, Self.luminance(hex)) >= 3, "\(world.name) marks on \(hex)")
            }
        }
    }

    @Test func lightWorldsDarkenAtNightAndNightWorldsStay() {
        #expect(CadenceWorld.all.count == 12)
        for world in CadenceWorld.all {
            #expect((world.bg.light == world.bg.dark) == world.isNight, "\(world.name)")
        }
        // #FF9A6B scaled by 0.84 per channel.
        #expect(CadenceWorld.coral.bg.dark == "#D6815A")
    }

    @Test func everyBarHueMeetsMarkContrastOnEveryBar() {
        for bar in BarHue.Bar.allCases {
            let ground = Self.luminance(bar.reference)
            for hue in CadenceBarColor.all {
                let (r, g, b) = hue.rgb(on: bar)
                #expect(Self.contrast(Self.luminance(r, g, b), ground) >= 3, "\(hue.name) on \(bar)")
            }
        }
    }

    @Test func barHuesShareOneLightnessPerBar() {
        // Equal OKLCH lightness keeps every accent within a narrow band of luminance on the same bar.
        for bar in BarHue.Bar.allCases {
            let values = CadenceBarColor.all.map { hue -> Double in
                let (r, g, b) = hue.rgb(on: bar)
                return Self.luminance(r, g, b)
            }
            #expect(values.max()! - values.min()! < 0.08, "\(bar)")
        }
    }

    @Test func typeSizesComeFromTheScale() {
        let sizes: Set<CGFloat> = [11, 12, 13, 14, 15, 18, 22, 28, 34, 38, 44, 58, 68]
        for token in CadenceType.all {
            #expect(sizes.contains(token.size), "\(token.name)")
            #expect(Int(token.lineHeight) % 4 == 0, "\(token.name)")
        }
    }

    /// The faint fill alone is below 3:1, so its full-ink hairline carries the tile; the fill still reads lighter.
    @Test func faintTilesMeetMarkContrastOnEveryDeepGround() {
        for deep in CadenceDeep.all {
            let ground = Self.luminance(deep.bg.light), ink = Self.luminance(deep.ink.light)
            let (ir, ig, ib, _) = ColorToken.channels(deep.ink.light), (br, bg, bb, _) = ColorToken.channels(deep.bg.light)
            let a = RecapTokens.faintOpacity
            func over(_ f: Double, _ b: Double) -> Double { f * a + b * (1 - a) }
            let fill = Self.luminance(over(Double(ir), Double(br)), over(Double(ig), Double(bg)), over(Double(ib), Double(bb)))
            #expect(Self.contrast(ink, ground) >= 3, "faint edge on \(deep.name)")
            #expect(Self.contrast(fill, ground) < Self.contrast(ink, ground), "faint fill lighter than full on \(deep.name)")
        }
        #expect(RecapTokens.faintStroke < RecapTokens.tileStroke)
    }

    /// Light work colours below 3:1 gain an `ink` edge; dark ones pass on their own (decision of 2026-11-03).
    @MainActor @Test func kindDotsMeetMarkContrastOnEveryGround() {
        let grounds = [CadenceColor.card, CadenceColor.canvas, CadenceColor.track]
        #expect(FamilyDot.edged(.light, .standard) && FamilyDot.edged(.light, .increased) && FamilyDot.edged(.dark, .increased))
        #expect(!FamilyDot.edged(.dark, .standard))
        for family in Family.allCases where family != .presence {
            let token = CadenceColor.family(family)
            for ground in grounds {
                let light = Self.luminance(ground.light), dark = Self.luminance(ground.dark)
                #expect(Self.contrast(Self.luminance(CadenceColor.ink.light), light) >= 3, "\(token.name) edge on \(ground.name)")
                #expect(Self.contrast(Self.luminance(CadenceColor.ink.dark), dark) >= 3, "\(token.name) edge on \(ground.name), dark")
                #expect(Self.contrast(Self.luminance(token.dark), dark) >= 3, "\(token.name) on \(ground.name), dark")
            }
        }
    }

    @Test func increaseContrastThickensIconStrokes() {
        #expect(CadenceIcon.stroke(2, .standard) == 2)
        #expect(CadenceIcon.stroke(2, .increased) == 3)
        #expect(CadenceIcon.weight(.regular, .standard) == .regular)
        #expect(CadenceIcon.weight(.regular, .increased) == .medium)
        #expect(CadenceIcon.weight(.bold, .increased) == .heavy)
        #expect(CadenceIcon.weight(.black, .increased) == .black)
    }
}
