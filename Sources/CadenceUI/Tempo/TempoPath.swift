// SVG path data to a SwiftUI path, so Tempo is drawn from the prototype's own path strings rather than a retracing.
// Covers what the prototype uses: M L H V C S Q T A Z, absolute and relative, with packed numbers and arc flags.
import Foundation
import SwiftUI

enum TempoPath {
    /// Parses SVG path data. Unknown commands end the path where they stand.
    static func parse(_ data: String) -> Path {
        var scanner = Scanner(Array(data.utf8))
        var path = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuad: CGPoint?
        var command: UInt8 = 0

        while true {
            scanner.skipSeparators()
            guard let byte = scanner.peek() else { break }
            if Scanner.isCommand(byte) {
                command = byte
                scanner.advance()
            } else if command == 0 {
                break
            }
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            var control: CGPoint?
            var quad: CGPoint?

            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p
                start = p
                // Further pairs after a move are lines.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                control = c2
                current = p
            case UInt8(ascii: "s"):
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                control = c2
                current = p
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quad = c
                current = p
            case UInt8(ascii: "t"):
                let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quad = c
                current = p
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                    let large = scanner.flag(), let sweep = scanner.flag(), let p = point()
                else { return path }
                addArc(&path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
                command = 0
            default:
                return path
            }
            lastControl = control
            lastQuad = quad
        }
        return path
    }

    /// An SVG elliptical arc as cubic curves, from the endpoint form (SVG 1.1 implementation notes, F.6.5 and F.6.6).
    static func addArc(
        _ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool
    ) {
        var rx = abs(rx)
        var ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let (cosPhi, sinPhi) = (cos(phi), sin(phi))
        let dx = (p0.x - p1.x) / 2
        let dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = (max(0, numerator) / denominator).squareRoot()
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry
        let cy1 = -factor * ry * x1 / rx
        let center = CGPoint(
            x: cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2,
            y: sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        )
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func on(_ t: CGFloat) -> CGPoint {
            let (x, y) = (rx * cos(t), ry * sin(t))
            return CGPoint(x: center.x + cosPhi * x - sinPhi * y, y: center.y + sinPhi * x + cosPhi * y)
        }
        func tangent(_ t: CGFloat) -> CGPoint {
            let (x, y) = (-rx * sin(t), ry * cos(t))
            return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
        }
        var t = theta1
        for index in 0..<segments {
            let a = on(t)
            let b = index == segments - 1 ? p1 : on(t + step)
            let da = tangent(t)
            let db = tangent(t + step)
            path.addCurve(
                to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y)
            )
            t += step
        }
    }

    /// Reads numbers the way SVG writes them: "5.6.6" is two numbers and "4-5.5" is two more.
    struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func advance() { index += 1 }

        static func isCommand(_ b: UInt8) -> Bool {
            switch b | 0x20 {
            case UInt8(ascii: "m"), UInt8(ascii: "l"), UInt8(ascii: "h"), UInt8(ascii: "v"), UInt8(ascii: "c"), UInt8(ascii: "s"),
                UInt8(ascii: "q"), UInt8(ascii: "t"), UInt8(ascii: "a"), UInt8(ascii: "z"):
                return true
            default:
                return false
            }
        }

        mutating func skipSeparators() {
            while let b = peek(), b == UInt8(ascii: " ") || b == UInt8(ascii: ",") || b == 0x0A || b == 0x09 || b == 0x0D {
                advance()
            }
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard let b = peek(), b == UInt8(ascii: "0") || b == UInt8(ascii: "1") else { return nil }
            advance()
            return b == UInt8(ascii: "1")
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if let b = peek(), b == UInt8(ascii: "-") || b == UInt8(ascii: "+") { advance() }
            var digits = false
            var dot = false
            while let b = peek() {
                if b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") {
                    digits = true
                } else if b == UInt8(ascii: "."), !dot {
                    dot = true
                } else {
                    break
                }
                advance()
            }
            if digits, let b = peek(), b == UInt8(ascii: "e") || b == UInt8(ascii: "E") {
                advance()
                if let s = peek(), s == UInt8(ascii: "-") || s == UInt8(ascii: "+") { advance() }
                while let d = peek(), d >= UInt8(ascii: "0"), d <= UInt8(ascii: "9") { advance() }
            }
            guard digits, let text = String(bytes: bytes[begin..<index], encoding: .ascii), let value = Double(text) else {
                index = begin
                return nil
            }
            return CGFloat(value)
        }
    }
}
