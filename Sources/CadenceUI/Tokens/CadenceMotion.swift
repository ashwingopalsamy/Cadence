// Motion tokens (docs/SPEC.md sections 4.1 and 5.7). Motion confirms and then stops; Reduce Motion removes every
// animation and keeps the end states.
import SwiftUI

public struct MotionToken: Sendable, Identifiable {
    public enum Curve: Sendable {
        case ease
        case spring
    }

    public let name: String
    public let usedFor: String
    public let duration: TimeInterval
    public let curve: Curve

    public var id: String { name }

    public var animation: Animation {
        switch curve {
        case .ease:
            let c = CadenceMotion.ease
            return .timingCurve(c.x1, c.y1, c.x2, c.y2, duration: duration)
        case .spring:
            return .spring(response: duration, dampingFraction: CadenceMotion.springDamping)
        }
    }
}

public enum CadenceMotion {
    public struct Curve: Sendable {
        public let x1: Double
        public let y1: Double
        public let x2: Double
        public let y2: Double
    }

    public static let ease = Curve(x1: 0.22, y1: 0.61, x2: 0.36, y2: 1)

    public static let press = MotionToken(name: "press", usedFor: "Press and hover", duration: 0.12, curve: .ease)
    public static let open = MotionToken(name: "open", usedFor: "Panel and sheet open", duration: 0.18, curve: .ease)
    public static let world = MotionToken(name: "world", usedFor: "Colour world change, menu-bar crossfade", duration: 0.45, curve: .ease)
    public static let tick = MotionToken(name: "tick", usedFor: "Task tick", duration: 0.22, curve: .spring)
    public static let entry = MotionToken(name: "entry", usedFor: "New entry appears", duration: 0.42, curve: .spring)
    public static let sweep = MotionToken(name: "sweep", usedFor: "Sealing sweep", duration: 1.4, curve: .ease)
    public static let recapTile = MotionToken(name: "recap tile", usedFor: "Recap tiles, staggered", duration: 0.36, curve: .spring)
    public static let markRise = MotionToken(name: "mark rise", usedFor: "Menu-bar water after a tick", duration: 0.3, curve: .ease)
    public static let markSeal = MotionToken(name: "mark seal", usedFor: "Menu-bar water closing into a disc", duration: 0.6, curve: .ease)
    public static let breath = MotionToken(name: "breath", usedFor: "Menu-bar attention, then held", duration: 1.6, curve: .ease)
    public static let bubbles = MotionToken(name: "bubbles", usedFor: "Tempo bubbles, on lively days only", duration: 1.6, curve: .ease)

    public static let all = [press, open, world, tick, entry, sweep, recapTile, markRise, markSeal, breath, bubbles]

    /// Attention breathes this many times at onset, then holds. It never loops.
    public static let breaths = 3
    /// Tempo plays its one gesture for this many beats when a surface opens or the state changes, then holds.
    public static let tempoBeats = 8

    public static let springResponse = 0.35
    public static let springDamping = 0.8
    public static let spring = Animation.spring(response: springResponse, dampingFraction: springDamping)

    /// The ease curve at `t` in 0...1, for motion drawn frame by frame. Solves the bezier's x for t, then reads its y.
    public static func easeProgress(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        func axis(_ u: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u
        }
        var (low, high) = (0.0, 1.0)
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if axis(middle, ease.x1, ease.x2) < t { low = middle } else { high = middle }
        }
        return axis((low + high) / 2, ease.y1, ease.y2)
    }

    /// The spring at `elapsed` seconds, for motion drawn frame by frame. It passes 1 once and settles on it.
    public static func springProgress(elapsed: TimeInterval) -> Double {
        let natural = 2 * Double.pi / springResponse
        let damped = natural * (1 - springDamping * springDamping).squareRoot()
        let decay = exp(-springDamping * natural * elapsed)
        return 1 - decay * (cos(damped * elapsed) + springDamping * natural / damped * sin(damped * elapsed))
    }

    /// The animation to use, or nil under Reduce Motion.
    public static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

extension View {
    /// `animation(_:value:)` that honours Reduce Motion.
    public func cadenceAnimation(_ animation: Animation, value: some Equatable) -> some View {
        modifier(CadenceAnimationModifier(animation: animation, value: value))
    }
}

private struct CadenceAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(CadenceMotion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}
