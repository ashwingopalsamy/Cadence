// Motion tokens (docs/SPEC.md section 5.7). Reduce Motion removes every animation and keeps the end states.
import SwiftUI

public struct MotionToken: Sendable, Identifiable {
    public let name: String
    public let usedFor: String
    public let duration: TimeInterval

    public var id: String { name }

    public var animation: Animation {
        let c = CadenceMotion.ease
        return .timingCurve(c.x1, c.y1, c.x2, c.y2, duration: duration)
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

    public static let fast = MotionToken(name: "fast", usedFor: "Hover, press, chip toggles", duration: 0.12)
    public static let base = MotionToken(name: "base", usedFor: "Panels, satellite fade, list insertions", duration: 0.18)
    public static let slow = MotionToken(name: "slow", usedFor: "Pocket open, sheet steps", duration: 0.24)
    public static let arc = MotionToken(name: "arc", usedFor: "Ring and dot progress changes", duration: 0.4)

    public static let all = [fast, base, slow, arc]

    /// Day start pip, seal pop, milestone. Nothing else.
    public static let springResponse = 0.35
    public static let springDamping = 0.8
    public static let spring = Animation.spring(response: springResponse, dampingFraction: springDamping)

    /// Numbers fade in the direction of change; no digit rolls.
    public static let valueChangeOut: TimeInterval = 0.07
    public static let valueChangeIn: TimeInterval = 0.16
    public static let valueChangeShift: CGFloat = 6

    public static let valueOut = MotionToken(name: "value out", usedFor: "Number leaving", duration: valueChangeOut)
    public static let valueIn = MotionToken(name: "value in", usedFor: "Number arriving", duration: valueChangeIn)

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

    /// The spring token at `elapsed` seconds, for motion drawn frame by frame. It passes 1 once and settles on it.
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
