// Draws Tempo the way the approved prototype's `tempo()` does, in its 100 by 124 viewBox and in the same order:
// shadow; then, inside the body move, the tilt and the pose's own transform: legs behind, arms behind, the glass with
// its water, the head prop, legs in front, the front prop, arms in front; and the badge last, outside every move.
// `elapsed` is the time since the gesture started, or nil for the held pose, which reads no clock at all.
import SwiftUI

private typealias T = CadenceTempoTokens

enum TempoGeometry {
    /// The bubbles: x, radius, and delay in seconds. A lively day shows the first one to three.
    static let bubbles: [(x: CGFloat, radius: CGFloat, delay: TimeInterval)] = [(40, 2.2, 0), (58, 1.6, 0.42), (64, 2.6, 0.9)]
}

/// The prototype rounds coordinates to one decimal before writing them; so does Tempo here.
@inline(__always) func f1(_ v: CGFloat) -> CGFloat { (v * 10).rounded() / 10 }

struct TempoRenderer {
    let spec: TempoSpec
    let elapsed: TimeInterval?

    private var pose: TempoPose { spec.pose }
    private var motion: TempoMotion { TempoMotion(beat: spec.beat, elapsed: spec.moves ? elapsed : nil) }

    func draw(in context: GraphicsContext, size: CGSize) {
        var c = context
        let scale = size.width / T.viewBox.width
        c.scaleBy(x: scale, y: scale)
        c.translateBy(x: -T.viewBox.minX, y: -T.viewBox.minY)
        let ink = Ink(c)
        let pose = pose
        let lie = pose.legs == .lie

        // Shadow on the ground, outside every move.
        ink.ellipse(lie ? 46 : 50, 104, lie ? 36 : 28, 3.5, T.shadow)

        // The gesture's body move, then the tilt, both around the feet.
        var body = ink
        if let move = pose.gesture?.body {
            body = body.around(T.groundPivot) { c in
                switch move {
                case .breathe:
                    let s = motion.breathe()
                    c.scaleBy(x: s.width, y: s.height)
                case .rock: c.rotate(by: .degrees(motion.rock()))
                case .hop: c.translateBy(x: 0, y: motion.hop())
                }
            }
        }
        if pose.tilt != 0 { body = body.rotated(pose.tilt, about: T.groundPivot) }
        // Sitting lowers the globe, lying turns it on its side, hopping lifts it.
        switch pose.legs {
        case .lie:
            body = body.around(T.glassCenter) { c in
                c.translateBy(x: -2, y: 10)
                c.rotate(by: .degrees(-80))
            }
        case .sit, .cross: body = body.translated(0, 5)
        case .hop: body = body.translated(0, -5)
        default: break
        }

        let stepping = pose.gesture?.feet == true
        legs(body, front: false, stepping: stepping)
        if !pose.left.front { arm(body, side: -1, pose.left, prop: pose.heldLeft, swing: pose.gesture?.left) }
        if !pose.right.front { arm(body, side: 1, pose.right, prop: pose.heldRight, swing: pose.gesture?.right) }
        glass(body)
        if let head = pose.head { TempoProps.draw(head, at: .zero, body) }
        legs(body, front: true, stepping: stepping)
        if let front = pose.front { TempoProps.draw(front, at: CGPoint(x: 50, y: 84), body) }
        if pose.left.front { arm(body, side: -1, pose.left, prop: pose.heldLeft, swing: pose.gesture?.left) }
        if pose.right.front { arm(body, side: 1, pose.right, prop: pose.heldRight, swing: pose.gesture?.right) }

        if let badge = pose.badge { self.badge(badge, ink) }
    }

    // MARK: Glass, water, face

    private func glass(_ ink: Ink) {
        let (cx, cy) = (T.glassCenter.x, T.glassCenter.y)
        let r = T.glassRadius
        let ri = T.waterRadius
        let level = spec.level
        ink.circle(cx, cy, r, T.glass)

        let inside = ink.clipped(to: Path(ellipseIn: CGRect(x: cx - ri, y: cy - ri, width: 2 * ri, height: 2 * ri)))
        if level > 0 { water(inside, level: level) }
        if spec.showsBubbles, let elapsed = motion.elapsed {
            let top = cy + ri - 2 * ri * level
            let rise = -f1(cy + ri - 12 - top)
            for bubble in TempoGeometry.bubbles.prefix(spec.bubbles) {
                guard let (offset, opacity) = TempoMotion.bubble(elapsed: elapsed - bubble.delay) else { continue }
                inside.circle(bubble.x, f1(cy + ri - 8) + rise * offset, bubble.radius, Color.white.opacity(opacity))
            }
        }

        for d in [-14.0, 0, 14] {
            ink.stroke("M20 \(cy + d)h\(d != 0 ? 4 : 6)", T.metre, 2, round: true)
        }
        ink.strokeCircle(cx, cy, r - 1.6, T.highlight, 3.2)
        ink.strokeCircle(cx, cy, r, T.glassEdge, 1.2)
        ink.stroke("M27.5 44A26 26 0 0 1 43 30.5", T.highlight, 5, round: true)
        ink.circle(48.5, 29.5, 2.4, T.highlight)
        face(ink, cx: cx, ey: T.eyeLine)
    }

    private func water(_ ink: Ink, level: Double) {
        let (cy, ri) = (T.glassCenter.y, T.waterRadius)
        let y = f1(cy + ri - 2 * ri * level)
        let surface = spec.surface
        let top: String =
            switch surface {
            case .choppy: "M2 \(y)q6-4.6 12 0" + String(repeating: "t12 0", count: 7)
            case .calm: "M2 \(y)q12-1.4 24 0t24 0t24 0t24 0"
            case .still: "M2 \(y)H98"
            case .dotted: "M2 \(y)q12-2 24 0t24 0t24 0t24 0"
            case .wave: "M2 \(y)q12-3.2 24 0t24 0t24 0t24 0"
            }
        var sloshed = ink
        if surface != .still {
            let m = T.Motion.self
            let amp = surface == .choppy ? m.sloshChoppy : surface == .calm ? m.sloshCalm : m.sloshWave
            sloshed = ink.rotated(motion.swing(amp), about: CGPoint(x: T.glassCenter.x, y: y))
        }
        sloshed.fill(top + "V104H2z", T.coral)
        sloshed.stroke(top, T.waterSurface, 3, round: surface == .dotted, dash: surface == .dotted ? [3, 4] : [])
    }

    /// One face: eyes 22 apart, mouth 10 below, soft cheeks. Line marks are 3 wide: the prototype's narrower widths
    /// repeat an attribute that HTML drops, so the approved drawing shows 3.
    private func face(_ ink: Ink, cx: CGFloat, ey: CGFloat) {
        let k = T.ink
        let my = ey + 10
        let (l, r) = (cx - 11, cx + 11)
        func line(_ d: String) { ink.stroke(d, k, 3, round: true) }
        func eye(_ x: CGFloat, big: Bool = false, dx: CGFloat = 0, dy: CGFloat = 0) {
            ink.ellipse(x + dx, ey + dy, big ? 4.2 : 3.2, big ? 4.6 : 4.4, k)
            ink.circle(x + dx + 1, ey + dy - 1.6, 1.1, .white)
        }

        if pose.eyes != .shades {
            let blush = T.blush.opacity(pose.eyes == .droopy ? 0.5 : 0.26)
            ink.ellipse(cx - 17, ey + 7, 4.5, 2.6, blush)
            ink.ellipse(cx + 17, ey + 7, 4.5, 2.6, blush)
        }

        switch pose.eyes {
        case .open: eye(l); eye(r)
        case .wide: eye(l, big: true); eye(r, big: true)
        case .aside: eye(l, dx: -3); eye(r, dx: -3)
        case .down: eye(l, dy: 2.4); eye(r, dy: 2.4)
        case .happy: line("M\(l - 4) \(ey + 1.5)q4-5.5 8 0M\(r - 4) \(ey + 1.5)q4-5.5 8 0")
        case .calm: line("M\(l - 3.5) \(ey + 1)h7M\(r - 3.5) \(ey + 1)h7")
        case .closed: line("M\(l - 4) \(ey - 1)q4 4.5 8 0M\(r - 4) \(ey - 1)q4 4.5 8 0")
        case .droopy:
            line("M\(l - 4) \(ey)h8M\(r - 4) \(ey)h8")
            ink.fill("M\(l - 3) \(ey + 1.5)q3 3.4 6 0zM\(r - 3) \(ey + 1.5)q3 3.4 6 0z", k)
        case .one:
            line("M\(l - 4) \(ey + 1.5)q4-5.5 8 0")
            eye(r)
        case .worried:
            eye(l)
            eye(r)
            line("M\(l - 4) \(ey - 7.5)l7.5-2.2M\(r + 4) \(ey - 7.5)l-7.5-2.2")
        case .shades:
            let lens = { (x: CGFloat) in "M\(x - 7) \(ey - 4.5)h14v3.5a5 5 0 01-5 5h-4a5 5 0 01-5-5z" }
            ink.fill(lens(l) + lens(r), k)
            ink.stroke("M\(l + 7) \(ey - 3.5)h\(r - l - 14)", k, 2.4)
            ink.stroke("M\(l - 3) \(ey - 2.5)l3 3M\(r - 3) \(ey - 2.5)l3 3", Color.white.opacity(0.7), 1.2, round: true)
        }

        switch pose.mouth {
        case .smile: line("M\(cx - 5) \(my - 1)q5 4.5 10 0")
        case .grin:
            ink.fill("M\(cx - 7) \(my - 2.5)h14q0 9-7 9t-7-9z", k)
            ink.fill("M\(cx - 4) \(my + 4.6)q4-3.2 8 0q-1 1.9-4 1.9t-4-1.9z", T.tongue)
        case .yawn:
            ink.ellipse(cx, my + 1, 4.2, 5.4, k)
            ink.ellipse(cx, my + 3.6, 2.6, 1.8, T.tongue)
        case .rest: line("M\(cx - 3.5) \(my)h7")
        case .o: ink.ellipse(cx, my, 2.4, 2.9, k)
        case .worry: line("M\(cx - 5) \(my + 2)q5-4 10 0")
        }
    }

    // MARK: Limbs

    /// An arm: a two-tone capsule from the shoulder, bent at the elbow, ending in a round hand that can hold a prop.
    private func arm(_ ink: Ink, side: CGFloat, _ spec: TempoPose.Arm, prop: TempoPose.Prop?, swing: Double?) {
        func vector(_ degrees: Double) -> CGPoint {
            let r = degrees * .pi / 180
            return CGPoint(x: side * sin(r), y: cos(r))
        }
        let s = CGPoint(x: T.glassCenter.x + side * T.shoulderOffset, y: T.shoulderY)
        let u = vector(spec.shoulder)
        let w = vector(spec.shoulder + spec.elbow)
        let e = CGPoint(x: s.x + T.upperArm * u.x, y: s.y + T.upperArm * u.y)
        let h = CGPoint(x: e.x + T.forearm * w.x, y: e.y + T.forearm * w.y)
        let d = "M\(f1(s.x)) \(f1(s.y))L\(f1(e.x)) \(f1(e.y))L\(f1(h.x)) \(f1(h.y))"
        let shoulder = CGPoint(x: f1(s.x), y: f1(s.y))
        let hand = CGPoint(x: f1(h.x), y: f1(h.y))

        var g = ink
        if let swing, swing != 0 { g = ink.rotated(motion.swing(swing * side), about: shoulder) }
        g.stroke(d, T.shade, 9.6, round: true, join: true)
        g.translated(-0.8, -1).stroke(d, T.coral, 6.2, round: true, join: true)
        if let prop { TempoProps.draw(prop, at: hand, g) }
        g.circle(hand.x, hand.y, 5.6, T.shade)
        g.circle(hand.x - 0.9, hand.y - 1, 4.2, T.coral)
    }

    /// Feet and legs. Behind the glass for standing, in front of it for sitting.
    private func legs(_ ink: Ink, front: Bool, stepping: Bool) {
        func foot(_ x: CGFloat, _ y: CGFloat, _ r: Double = 0, _ i: Int = 0) {
            let g = stepping ? ink.translated(0, motion.step(foot: i)) : ink
            g.ellipse(x, y, 7.4, 4.4, T.shade, rotation: r)
            g.ellipse(x - 0.8, y - 1, 5.8, 3.2, T.coral, rotation: r, about: CGPoint(x: x, y: y))
        }
        func leg(_ x1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            ink.stroke("M\(x1) 88L\(x2) \(y2)", T.shade, 7.6, round: true)
            ink.stroke("M\(x1 - 0.6) 88L\(x2 - 0.6) \(y2)", T.coral, 4.4, round: true)
        }
        switch pose.legs {
        case .sit:
            guard front else { return }
            foot(31, 100, -24)
            foot(69, 100, 24, 1)
        case .cross:
            guard front else { return }
            ink.ellipse(50, 99, 25, 6.4, T.shade)
            ink.ellipse(49, 98, 23, 4.8, T.coral)
        case .stride:
            guard !front else { return }
            leg(43, 37, 98)
            foot(35, 100, -8)
            leg(57, 63, 96)
            foot(65, 98, 10, 1)
        case .tiptoe:
            guard !front else { return }
            leg(44, 43, 101)
            leg(56, 57, 101)
            foot(42, 102, -18)
            foot(58, 102, 18, 1)
        case .hop:
            guard !front else { return }
            leg(44, 42, 95)
            leg(56, 58, 95)
            foot(41, 96, -14)
            foot(59, 96, 14, 1)
        case .stand, .lie:
            guard !front else { return }
            leg(43, 41, 98)
            leg(57, 59, 98)
            foot(39, 100)
            foot(61, 100, 0, 1)
        }
    }

    // MARK: Badge

    /// Badges are kept for small signals only: a white disc at the top right carrying a symbol.
    private func badge(_ kind: TempoPose.Badge, _ ink: Ink) {
        let (bx, by) = (T.badgeCenter.x, T.badgeCenter.y)
        let k = T.ink
        ink.circle(bx, by + 1.5, 10.5, T.badgeShadow)
        ink.circle(bx, by, 10, .white)
        switch kind {
        case .sun:
            ink.circle(bx, by, 3, T.sun)
            for d in stride(from: 0.0, to: 360, by: 45) {
                let (s, c) = (sin(d * .pi / 180), cos(d * .pi / 180))
                ink.stroke(
                    "M\(f1(bx + 4.8 * s)) \(f1(by - 4.8 * c))L\(f1(bx + 6.6 * s)) \(f1(by - 6.6 * c))", T.sun, 1.6, round: true
                )
            }
        case .question: ink.text("?", bx - 3.9, by + 4.6, 13, k)
        case .z:
            ink.text("z", bx - 5.2, by + 5, 12, k)
            ink.text("z", bx + 1.6, by - 1, 8, k)
        case .confetti:
            ink.fill("M\(bx - 5) \(by + 6)L\(bx - 1) \(by - 4)L\(bx + 3) \(by + 2)z", T.Prop.pink)
            ink.circle(bx + 4, by - 4, 1.4, T.sun)
            ink.circle(bx + 5.5, by + 1, 1.2, T.Prop.blue)
            ink.circle(bx + 1, by - 6.5, 1.1, T.Prop.green)
        case .pause:
            ink.rect(bx - 3.6, by - 4, 2.6, 8, 1.2, k)
            ink.rect(bx + 1, by - 4, 2.6, 8, 1.2, k)
        case .heart:
            ink.fill(
                "M\(bx) \(by + 5)c-6-3.6-7.4-7-5.6-9.2c1.6-2 4.2-1.4 5.6.6c1.4-2 4-2.6 5.6-.6c1.8 2.2.4 5.6-5.6 9.2z", T.blush
            )
        case .bubble:
            for dx in [-4.0, 0, 4] { ink.circle(bx + dx, by, 1.5, k) }
        case .bang: ink.text("!", bx - 2.3, by + 5.2, 14, T.alarm)
        }
    }
}

// MARK: Motion

/// The prototype's keyframes, evaluated at a moment. Every move runs 8 two-beat cycles and comes home to rest.
struct TempoMotion {
    let beat: TimeInterval
    /// Nil when held: every move is at rest.
    let elapsed: TimeInterval?

    private var cycle: TimeInterval { beat * 2 }

    /// Progress through the current cycle, or nil once the 8 cycles have run.
    private func phase(offset: TimeInterval = 0) -> Double? {
        guard let elapsed, cycle > 0 else { return nil }
        let t = elapsed + offset
        guard t >= 0, t < cycle * Double(CadenceMotion.tempoBeats) else { return nil }
        return (t / cycle).truncatingRemainder(dividingBy: 1)
    }

    /// `tbeat`: out to `amp` degrees, back, out to minus `amp`, back, on sine curves.
    func swing(_ amp: Double) -> Double {
        guard let p = phase() else { return 0 }
        return Keyframes.value(p, [(0, 0), (0.25, amp), (0.5, 0), (0.75, -amp), (1, 0)], curves: [.sineOut, .sineIn, .sineOut, .sineIn])
    }

    /// `tstep`: each foot lifts in turn, the second half a cycle ahead.
    func step(foot: Int) -> CGFloat {
        guard let p = phase(offset: beat * Double(foot)) else { return 0 }
        return Keyframes.value(p, [(0, 0), (0.25, -T.Motion.step), (0.5, 0), (1, 0)], curves: [.easeInOut])
    }

    /// `tbreathe`: the glass swells a little and settles.
    func breathe() -> CGSize {
        guard let p = phase() else { return CGSize(width: 1, height: 1) }
        let b = T.Motion.breathe
        let x = Keyframes.value(p, [(0, 1), (0.5, b.width), (1, 1)], curves: [.easeInOut])
        let y = Keyframes.value(p, [(0, 1), (0.5, b.height), (1, 1)], curves: [.easeInOut])
        return CGSize(width: x, height: y)
    }

    /// `trock`: a sway either side.
    func rock() -> Double {
        guard let p = phase() else { return 0 }
        let a = T.Motion.rock
        return Keyframes.value(p, [(0, 0), (0.25, a), (0.75, -a), (1, 0)], curves: [.easeInOut])
    }

    /// `thop`: up and down, then a pause.
    func hop() -> CGFloat {
        guard let p = phase() else { return 0 }
        return Keyframes.value(p, [(0, 0), (0.3, -T.Motion.hop), (0.6, 0), (1, 0)], curves: [.easeInOut])
    }

    /// `tbub`: a bubble's rise (0 to 1 of its travel) and opacity, or nil while it waits or once it has risen 6 times.
    static func bubble(elapsed t: TimeInterval) -> (CGFloat, Double)? {
        let m = T.Motion.self
        guard t >= 0, t < m.bubbleRise * Double(m.bubbleRises) else { return nil }
        let p = (t / m.bubbleRise).truncatingRemainder(dividingBy: 1)
        let rise = CubicCurve.easeIn(p)
        let opacity = Keyframes.value(p, [(0, 0), (0.2, m.bubbleOpacity), (1, 0)], curves: [.easeIn])
        return (rise, opacity)
    }
}

/// CSS keyframes: each segment eases on its own timing curve.
enum Keyframes {
    static func value(_ p: Double, _ frames: [(Double, Double)], curves: [CubicCurve]) -> Double {
        for i in 1..<frames.count where p <= frames[i].0 {
            let (a, b) = (frames[i - 1], frames[i])
            let curve = curves[min(i - 1, curves.count - 1)]
            let local = b.0 > a.0 ? (p - a.0) / (b.0 - a.0) : 1
            return a.1 + (b.1 - a.1) * curve(local)
        }
        return frames.last?.1 ?? 0
    }
}

/// A CSS cubic-bezier timing curve.
struct CubicCurve {
    let x1: Double, y1: Double, x2: Double, y2: Double

    static let easeInOut = CubicCurve(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    static let easeIn = CubicCurve(x1: 0.42, y1: 0, x2: 1, y2: 1)
    static let sineOut = CubicCurve(x1: 0.61, y1: 1, x2: 0.88, y2: 1)
    static let sineIn = CubicCurve(x1: 0.12, y1: 0, x2: 0.39, y2: 0)

    func callAsFunction(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        func axis(_ u: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u
        }
        var (low, high) = (0.0, 1.0)
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if axis(middle, x1, x2) < t { low = middle } else { high = middle }
        }
        return axis((low + high) / 2, y1, y2)
    }
}

// MARK: Drawing

/// A graphics context with the SVG primitives the prototype uses. Strokes default to butt caps and miter joins, as SVG.
struct Ink {
    var c: GraphicsContext

    init(_ c: GraphicsContext) { self.c = c }

    func fill(_ d: String, _ color: Color) { c.fill(TempoPath.parse(d), with: .color(color)) }

    func stroke(_ d: String, _ color: Color, _ width: CGFloat, round: Bool = false, join: Bool = false, dash: [CGFloat] = []) {
        let style = StrokeStyle(
            lineWidth: width, lineCap: round ? .round : .butt, lineJoin: join ? .round : .miter, miterLimit: 4, dash: dash
        )
        c.stroke(TempoPath.parse(d), with: .color(color), style: style)
    }

    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: Color) {
        c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(color))
    }

    func strokeCircle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: Color, _ width: CGFloat) {
        c.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(color), lineWidth: width)
    }

    /// An ellipse, turned `rotation` degrees around `about` (its own centre by default).
    func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: Color, rotation: Double = 0, about: CGPoint? = nil) {
        let g = rotation == 0 ? self : rotated(rotation, about: about ?? CGPoint(x: x, y: y))
        g.c.fill(Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry)), with: .color(color))
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rx: CGFloat, _ color: Color) {
        let r = min(rx, w / 2, h / 2)
        c.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .circular), with: .color(color))
    }

    /// Text placed as SVG places it: `x` at the start of the line, `y` on the baseline, in the heaviest system weight.
    func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: Color) {
        let resolved = c.resolve(Text(string).font(.system(size: size, weight: .black)).foregroundStyle(color))
        let bounds = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let baseline = resolved.firstBaseline(in: bounds)
        c.draw(resolved, at: CGPoint(x: x, y: y - baseline), anchor: .topLeading)
    }

    func translated(_ x: CGFloat, _ y: CGFloat) -> Ink {
        var g = c
        g.translateBy(x: x, y: y)
        return Ink(g)
    }

    func rotated(_ degrees: Double, about p: CGPoint) -> Ink {
        guard degrees != 0 else { return self }
        return around(p) { $0.rotate(by: .degrees(degrees)) }
    }

    /// A CSS transform with its origin at `p`.
    func around(_ p: CGPoint, _ transform: (inout GraphicsContext) -> Void) -> Ink {
        var g = c
        g.translateBy(x: p.x, y: p.y)
        transform(&g)
        g.translateBy(x: -p.x, y: -p.y)
        return Ink(g)
    }

    func clipped(to path: Path) -> Ink {
        var g = c
        g.clip(to: path)
        return Ink(g)
    }
}
