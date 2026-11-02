// Draws a pose as a template image, so macOS tints it for the menu bar in every mode (docs/SPEC.md section 4.1).
import AppKit

public enum DotRenderer {
    public static func image(_ pose: DotPose, highContrast: Bool = false) -> NSImage {
        let side = CadenceDotTokens.glyph
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(pose, in: context, center: CGPoint(x: rect.midX, y: rect.midY), highContrast: highContrast)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ pose: DotPose, in c: CGContext, center: CGPoint, highContrast: Bool) {
        let tokens = CadenceDotTokens.self
        let stroke = highContrast ? tokens.strokeHighContrast : tokens.stroke
        let hairline = highContrast ? tokens.strokeHighContrast : tokens.hairline
        func alpha(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) * min(max(pose.opacity, 0), 1) }
        func ink(_ value: CGFloat) -> CGColor { CGColor(gray: 0, alpha: alpha(value)) }
        func circle(radius: CGFloat) -> CGRect {
            CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }

        c.setLineCap(.round)
        c.setLineJoin(.round)

        if pose.outer > 0 {
            c.setStrokeColor(ink(pose.outer))
            c.setLineWidth(hairline)
            c.strokeEllipse(in: circle(radius: tokens.outerRadius))
        }
        if pose.track > 0 {
            c.setStrokeColor(ink(pose.track))
            c.setLineWidth(stroke)
            c.strokeEllipse(in: circle(radius: tokens.arcRadius))
        }
        if pose.arc > 0 {
            // From twelve o'clock, clockwise.
            let start = CGFloat.pi / 2
            c.setStrokeColor(ink(1))
            c.setLineWidth(stroke)
            c.addArc(
                center: center, radius: tokens.arcRadius, startAngle: start,
                endAngle: start - 2 * .pi * min(pose.arc, 1), clockwise: true)
            c.strokePath()
        }
        if pose.hollow > 0 {
            c.setStrokeColor(ink(pose.hollow))
            c.setLineWidth(stroke)
            c.strokeEllipse(in: circle(radius: pose.core > 0 ? tokens.coreRadius : tokens.arcRadius))
        }
        if pose.core > 0 {
            let radius = tokens.coreRadius * pose.core
            c.saveGState()
            // The lower share fills, so the paused core reads as half full.
            let filled = 2 * radius * min(max(pose.coreFill, 0), 1)
            c.clip(to: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: filled))
            c.setFillColor(ink(1))
            c.fillEllipse(in: circle(radius: radius))
            c.restoreGState()
        }
        if pose.dash > 0 {
            let half = tokens.dashLength / 2
            c.setStrokeColor(ink(pose.dash))
            c.setLineWidth(stroke)
            c.move(to: CGPoint(x: center.x - half, y: center.y))
            c.addLine(to: CGPoint(x: center.x + half, y: center.y))
            c.strokePath()
        }
        if pose.triangle > 0 {
            let r = tokens.arcRadius + stroke / 2
            c.setStrokeColor(ink(pose.triangle))
            c.setLineWidth(stroke)
            for (index, degrees) in [CGFloat(90), 210, 330].enumerated() {
                let point = CGPoint(x: center.x + r * cos(degrees * .pi / 180), y: center.y + r * sin(degrees * .pi / 180))
                if index == 0 { c.move(to: point) } else { c.addLine(to: point) }
            }
            c.closePath()
            c.strokePath()
        }
        if pose.satellite > 0 {
            let angle = (tokens.satelliteAngle - pose.orbit) * .pi / 180
            let place = CGPoint(
                x: center.x + tokens.arcRadius * cos(angle), y: center.y + tokens.arcRadius * sin(angle))
            func dot(_ radius: CGFloat) -> CGRect {
                CGRect(x: place.x - radius, y: place.y - radius, width: radius * 2, height: radius * 2)
            }
            c.saveGState()
            c.setBlendMode(.clear)
            c.fillEllipse(in: dot((tokens.satelliteRadius + tokens.satelliteGap) * min(max(pose.satellite, 0), 1)))
            c.restoreGState()
            c.setFillColor(ink(pose.satellite))
            c.fillEllipse(in: dot(tokens.satelliteRadius))
        }
    }
}
