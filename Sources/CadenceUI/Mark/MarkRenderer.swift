// Draws a MarkForm into the 18 pt status item (docs/SPEC.md section 4.1). The image carries its own colour, so it is
// not a template: neutral parts use the bar's own text colour and accents the OKLCH palette for that bar.
import AppKit
import CadenceCore

/// The bar the mark sits on: its palette (light, dark, or either under Increase Contrast) and its ink.
public struct MarkBar: Sendable, Equatable {
    public var palette: BarHue.Bar
    /// The bar's own text colour, opaque. The mark's opacities are relative to it.
    public var ink: CGColor

    public init(palette: BarHue.Bar, ink: CGColor) {
        self.palette = palette
        self.ink = ink
    }

    /// From the status button's effective appearance.
    public init(appearance: NSAppearance, increaseContrast: Bool) {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map {
            $0 == .darkAqua || $0 == .vibrantDark
        } ?? false
        var ink = NSColor.labelColor.cgColor
        appearance.performAsCurrentDrawingAppearance {
            ink = NSColor.labelColor.withAlphaComponent(1).cgColor
        }
        let palette: BarHue.Bar = dark ? (increaseContrast ? .darkMore : .dark) : (increaseContrast ? .lightMore : .light)
        self.init(palette: palette, ink: ink)
    }

    public var increaseContrast: Bool { palette == .lightMore || palette == .darkMore }
}

/// One frame of the mark's motion. Progress values are linear in time, 0...1; the renderer eases them.
public struct MarkMotion: Sendable, Equatable {
    /// The water level a tick rises from, or nil when the water is still.
    public var riseFrom: Double?
    /// How far through the rise, which also lifts the water's lightness for a moment.
    public var rise: Double
    /// How far the solid disc has closed.
    public var seal: Double
    /// The phase within one breath of the attention part, or nil when it holds still.
    public var breath: Double?
    /// The pointer is over the mark: the neutral ring lifts.
    public var hover: Bool

    public init(riseFrom: Double? = nil, rise: Double = 1, seal: Double = 1, breath: Double? = nil, hover: Bool = false) {
        self.riseFrom = riseFrom
        self.rise = rise
        self.seal = seal
        self.breath = breath
        self.hover = hover
    }

    public static let still = MarkMotion()
}

public enum MarkRenderer {
    public static var size: NSSize { NSSize(width: CadenceMarkTokens.side, height: CadenceMarkTokens.side) }

    public static func image(_ form: MarkForm, bar: MarkBar, motion: MarkMotion = .still) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(form, bar: bar, motion: motion, in: context)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The old mark fading into the new. `fraction` is linear in time, 0...1.
    public static func crossfade(from old: NSImage, to new: NSImage, fraction: Double) -> NSImage {
        let t = CadenceMotion.easeProgress(fraction)
        let image = NSImage(size: size, flipped: false) { rect in
            old.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1 - t)
            new.draw(in: rect, from: .zero, operation: .sourceOver, fraction: t)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws into a context whose y axis points down, with the mark's square at the origin.
    public static func draw(_ form: MarkForm, bar: MarkBar, motion: MarkMotion = .still, in c: CGContext) {
        let k = CadenceMarkTokens.self
        let breath = form.attention ? breathAlpha(motion.breath) : 1

        if let solid = form.solid {
            drawSolid(solid, bar: bar, seal: motion.seal, in: c)
            return
        }
        if let water = form.water {
            drawWater(water, bar: bar, motion: motion, in: c)
        }
        if let ring = form.ring {
            let thick = ring.kind == .thick
            let width = bar.increaseContrast
                ? (thick ? k.strokeThickHighContrast : k.strokeHighContrast)
                : (thick ? k.strokeThick : k.stroke)
            var alpha: CGFloat = ring.faint ? k.faint : 1
            if ring.paint == .ink {
                alpha *= bar.increaseContrast ? 1 : (motion.hover ? k.neutralRingHover : k.neutralRing)
            }
            c.saveGState()
            c.setStrokeColor(color(ring.paint, bar, alpha: alpha))
            c.setLineWidth(width)
            switch ring.kind {
            case .plain, .thick:
                c.addPath(circle(k.ringRadius))
            case .dashed:
                c.setLineDash(phase: 0, lengths: k.dash)
                c.addPath(circle(k.ringRadius))
            case .dotted:
                c.setLineCap(.round)
                c.setLineDash(phase: 0, lengths: k.dots)
                c.addPath(circle(k.ringRadius))
            case .openTop:
                c.setLineCap(.round)
                c.addPath(arc(k.openTop))
            case .broken:
                c.setLineCap(.round)
                c.addPath(arc(k.broken))
            }
            c.strokePath()
            c.restoreGState()
        }
        if let accent = form.accent {
            c.saveGState()
            c.setStrokeColor(color(.hue(accent.hue), bar, alpha: breath))
            c.setLineWidth(k.accentStroke)
            c.setLineCap(.round)
            switch accent.kind {
            case .notch:
                c.addPath(arc(k.notch))
            case .ears:
                c.addPath(arc(k.earLeft))
                c.addPath(arc(k.earRight))
            case .half:
                c.addPath(arc(k.half))
            case .halfDashed:
                c.setLineCap(.butt)
                c.setLineDash(phase: centredPhase(k.half), lengths: k.dash)
                c.addPath(arc(k.half))
            }
            c.strokePath()
            c.restoreGState()
        }
        switch form.centre {
        case .dot(let paint)?:
            c.setFillColor(color(paint, bar, alpha: breath))
            c.addPath(circle(k.centreDotRadius))
            c.fillPath()
        case .hollow(let paint)?:
            c.setStrokeColor(color(paint, bar, alpha: breath))
            c.setLineWidth(k.hollowCentreStroke)
            c.addPath(circle(k.hollowCentreRadius))
            c.strokePath()
        case nil:
            break
        }
    }

    // MARK: Parts

    private static func drawWater(_ water: MarkForm.Water, bar: MarkBar, motion: MarkMotion, in c: CGContext) {
        let k = CadenceMarkTokens.self
        // The level's share of the water's depth, never thinner than the meniscus, which is all of it at 0.
        func height(_ level: Double) -> CGFloat { max(k.meniscus, 2 * k.waterRadius * CGFloat(level)) }
        var brightness: CGFloat = 1
        var surface = height(water.level)
        if let from = motion.riseFrom, motion.rise < 1 {
            let p = min(1, max(0, motion.rise))
            // The surface starts where it was and eases to the new level.
            surface = height(from) + (surface - height(from)) * CGFloat(CadenceMotion.easeProgress(p))
            if p < k.liftHoldAt {
                let t = CGFloat(CadenceMotion.easeProgress(p / k.liftHoldAt))
                brightness = k.liftStart + (k.liftHold - k.liftStart) * t
            } else {
                let t = CGFloat(CadenceMotion.easeProgress((p - k.liftHoldAt) / (1 - k.liftHoldAt)))
                brightness = k.liftHold + (1 - k.liftHold) * t
            }
        }
        let top = k.centre.y + k.waterRadius - surface
        c.saveGState()
        c.addPath(circle(k.waterRadius))
        c.clip()
        c.setFillColor(color(.hue(water.hue), bar, alpha: CGFloat(water.softness), brightness: brightness))
        c.fill(CGRect(x: 0, y: top, width: k.side, height: k.side))
        c.restoreGState()
    }

    private static func drawSolid(_ solid: MarkForm.Solid, bar: MarkBar, seal: Double, in c: CGContext) {
        let k = CadenceMarkTokens.self
        let t = CGFloat(CadenceMotion.easeProgress(seal))
        let scale = k.sealScale + (1 - k.sealScale) * t
        c.saveGState()
        c.setAlpha(k.sealOpacity + (1 - k.sealOpacity) * t)
        c.translateBy(x: k.centre.x, y: k.centre.y)
        c.scaleBy(x: scale, y: scale)
        c.translateBy(x: -k.centre.x, y: -k.centre.y)
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        c.setFillColor(color(.hue(solid.hue), bar, alpha: 1))
        c.addPath(circle(k.discRadius))
        c.fillPath()
        // The cut is punched out of the disc, so the bar shows through it.
        c.setBlendMode(.destinationOut)
        c.setFillColor(CGColor(gray: 0, alpha: 1))
        c.setStrokeColor(CGColor(gray: 0, alpha: 1))
        switch solid.cut {
        case .none:
            break
        case .hollow:
            c.setLineWidth(k.hollowCutStroke)
            c.addPath(circle(k.hollowCutRadius))
            c.strokePath()
        case .bang:
            c.addPath(CGPath(roundedRect: k.bangBar, cornerWidth: k.bangBarCorner, cornerHeight: k.bangBarCorner, transform: nil))
            c.addPath(circle(k.bangDotRadius, at: k.bangDot))
            c.fillPath()
        }
        c.endTransparencyLayer()
        c.restoreGState()
    }

    // MARK: Geometry and colour

    /// A full circle, starting at three o'clock and running clockwise on screen, as an SVG circle's dashes do.
    private static func circle(_ radius: CGFloat, at centre: CGPoint = CadenceMarkTokens.centre) -> CGPath {
        let path = CGMutablePath()
        path.addRelativeArc(center: centre, radius: radius, startAngle: 0, delta: 2 * .pi)
        path.closeSubpath()
        return path
    }

    /// An arc on the ring, in degrees clockwise from twelve o'clock. y points down, so a growing angle runs clockwise.
    private static func arc(_ degrees: ClosedRange<CGFloat>) -> CGPath {
        let path = CGMutablePath()
        let start = (degrees.lowerBound - 90) * .pi / 180
        let delta = (degrees.upperBound - degrees.lowerBound) * .pi / 180
        path.addRelativeArc(center: CadenceMarkTokens.centre, radius: CadenceMarkTokens.ringRadius, startAngle: start, delta: delta)
        return path
    }

    /// A dash phase that centres whole dashes on an arc, so it never ends in a sliver.
    private static func centredPhase(_ degrees: ClosedRange<CGFloat>) -> CGFloat {
        let (dash, gap) = (CadenceMarkTokens.dash[0], CadenceMarkTokens.dash[1])
        let length = CadenceMarkTokens.ringRadius * (degrees.upperBound - degrees.lowerBound) * .pi / 180
        let count = ((length + gap) / (dash + gap)).rounded(.down)
        let margin = (length - (count * dash + (count - 1) * gap)) / 2
        return (dash + gap) - margin
    }

    private static func color(_ paint: MarkPaint, _ bar: MarkBar, alpha: CGFloat, brightness: CGFloat = 1) -> CGColor {
        let base: CGColor
        switch paint {
        case .ink: base = bar.ink
        case .hue(let hue): base = hue.token.nsColor(on: bar.palette).cgColor
        }
        let srgb = base.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? base
        let parts = srgb.components ?? [0, 0, 0, 1]
        let rgb = parts.count >= 3 ? Array(parts.prefix(3)) : [parts[0], parts[0], parts[0]]
        let lifted = rgb.map { min(1, $0 * brightness) }
        return CGColor(srgbRed: lifted[0], green: lifted[1], blue: lifted[2], alpha: (parts.last ?? 1) * alpha)
    }

    /// Opacity through one breath: full, down to the floor at the middle, and back, on a smooth curve.
    static func breathAlpha(_ phase: Double?) -> CGFloat {
        guard let phase else { return 1 }
        let floor = CadenceMarkTokens.breathFloor
        return floor + (1 - floor) * CGFloat(1 + cos(2 * .pi * phase)) / 2
    }
}
