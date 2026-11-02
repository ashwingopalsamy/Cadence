// The dot as numbers: every form is a pose, and every motion moves between two poses (docs/SPEC.md sections 4.1, 5.7).
import Foundation

public struct DotPose: Sendable, Equatable {
    public var opacity: CGFloat = 1
    /// Hollow ring at the core's place.
    public var hollow: CGFloat = 0
    /// Core radius as a share of the token. Above 1 is the sealed pop.
    public var core: CGFloat = 0
    /// Share of the core drawn: 1 is whole, 0.5 is the paused half.
    public var coreFill: CGFloat = 1
    public var track: CGFloat = 0
    public var arc: CGFloat = 0
    public var satellite: CGFloat = 0
    /// Degrees added to the satellite's place, for the orbit.
    public var orbit: CGFloat = 0
    public var outer: CGFloat = 0
    public var dash: CGFloat = 0
    public var triangle: CGFloat = 0

    public init(_ appearance: DotAppearance) {
        let tokens = CadenceDotTokens.self
        let progress = CGFloat(appearance.progress ?? 0)
        switch appearance.state {
        case .resting, .onCall:
            opacity = tokens.restingOpacity
            hollow = 1
        case .dayStarted:
            core = 1
            track = tokens.trackOpacity
        case .planPending:
            core = 1
            track = tokens.trackOpacity
            satellite = 1
        case .inProgress:
            core = 1
            track = tokens.trackOpacity
            arc = progress
        case .agentLogged, .wrapUpDue:
            core = 1
            track = tokens.trackOpacity
            arc = progress
            satellite = 1
        case .sealed:
            core = tokens.sealedCoreScale
            arc = 1
        case .leave:
            dash = 1
        case .paused:
            core = 1
            coreFill = 0.5
            hollow = 1
        case .needsAttention:
            triangle = 1
        }
        outer = appearance.onCall || appearance.state == .onCall ? 1 : 0
        if appearance.state == .onCall { opacity = 1 }
    }

    /// `t` may leave 0...1, which is how a spring overshoots. Opacities are clamped when drawn.
    public static func mix(_ a: DotPose, _ b: DotPose, _ t: CGFloat) -> DotPose {
        func m(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        var p = a
        p.opacity = m(a.opacity, b.opacity)
        p.hollow = m(a.hollow, b.hollow)
        p.core = m(a.core, b.core)
        p.coreFill = m(a.coreFill, b.coreFill)
        p.track = m(a.track, b.track)
        p.arc = m(a.arc, b.arc)
        p.satellite = m(a.satellite, b.satellite)
        p.outer = m(a.outer, b.outer)
        p.dash = m(a.dash, b.dash)
        p.triangle = m(a.triangle, b.triangle)
        return p
    }
}

/// The motion of a change, from the table in section 4.1.
public struct DotMotion: Sendable, Equatable {
    public enum Curve: Sendable, Equatable {
        case ease, spring
    }

    public var duration: TimeInterval
    public var curve: Curve
    /// One full turn of the satellite over the duration.
    public var orbits: Bool
    /// One swell of the core and back over the duration.
    public var pulses: Bool

    public static let instant = DotMotion(duration: 0, curve: .ease, orbits: false, pulses: false)

    /// Reduce Motion removes every animation and keeps the end state.
    public static func between(_ from: DotAppearance, _ to: DotAppearance, reduceMotion: Bool) -> DotMotion {
        guard !reduceMotion, from != to else { return .instant }
        let tokens = CadenceDotTokens.self
        if from.state != to.state {
            switch to.state {
            case .dayStarted:
                return DotMotion(duration: tokens.pipDuration, curve: .spring, orbits: false, pulses: false)
            case .planPending:
                return DotMotion(duration: tokens.satelliteFade, curve: .ease, orbits: false, pulses: false)
            case .agentLogged:
                return DotMotion(duration: tokens.orbitDuration, curve: .ease, orbits: true, pulses: false)
            case .wrapUpDue:
                return DotMotion(duration: tokens.pulseDuration, curve: .ease, orbits: false, pulses: true)
            case .sealed:
                return DotMotion(duration: tokens.arcChange, curve: .spring, orbits: false, pulses: false)
            case .inProgress:
                return DotMotion(duration: tokens.arcChange, curve: .ease, orbits: false, pulses: false)
            case .resting, .onCall, .leave, .paused, .needsAttention:
                // The table gives these no motion.
                return .instant
            }
        }
        return from.progress != to.progress
            ? DotMotion(duration: tokens.arcChange, curve: .ease, orbits: false, pulses: false) : .instant
    }

    /// Progress at `elapsed` seconds. A spring may pass 1 and settles on it.
    public func progress(at elapsed: TimeInterval) -> CGFloat {
        guard duration > 0, elapsed < duration else { return 1 }
        let t = max(0, elapsed) / duration
        switch curve {
        case .ease: return CGFloat(CadenceMotion.easeProgress(t))
        case .spring: return CGFloat(CadenceMotion.springProgress(elapsed: max(0, elapsed)))
        }
    }

    /// The pose at `elapsed` seconds on the way from one pose to another.
    public func pose(from: DotPose, to: DotPose, at elapsed: TimeInterval) -> DotPose {
        var pose = DotPose.mix(from, to, progress(at: elapsed))
        guard duration > 0, elapsed < duration else { return to }
        let t = CGFloat(max(0, elapsed) / duration)
        if orbits { pose.orbit = 360 * CGFloat(CadenceMotion.easeProgress(Double(t))) }
        if pulses { pose.core += CadenceDotTokens.pulseScale * sin(.pi * t) }
        return pose
    }
}
