// Dot tokens (docs/SPEC.md sections 4.1 and 5.7). Sizes are points inside the 16 pt glyph.
import Foundation

public enum CadenceDotTokens {
    public static let itemLength: CGFloat = 18
    public static let glyph: CGFloat = 16

    public static let stroke: CGFloat = 1.3
    /// Increase Contrast thickens strokes to this.
    public static let strokeHighContrast: CGFloat = 1.8
    public static let hairline: CGFloat = 0.75

    public static let outerRadius: CGFloat = 7.5
    public static let arcRadius: CGFloat = 5.4
    public static let coreRadius: CGFloat = 3.0
    public static let satelliteRadius: CGFloat = 1.6
    /// The clear gap the satellite cuts around itself, so it reads against the arc in one colour.
    public static let satelliteGap: CGFloat = 1
    /// One o'clock, in degrees counterclockwise from three o'clock.
    public static let satelliteAngle: CGFloat = 60
    public static let dashLength: CGFloat = 8

    public static let restingOpacity: CGFloat = 0.55
    public static let trackOpacity: CGFloat = 0.28
    public static let sealedCoreScale: CGFloat = 1.18
    public static let pulseScale: CGFloat = 0.2

    public static let pipDuration = CadenceMotion.slow.duration
    public static let satelliteFade = CadenceMotion.base.duration
    public static let arcChange = CadenceMotion.arc.duration
    public static let orbitDuration: TimeInterval = 0.7
    public static let pulseDuration = CadenceMotion.arc.duration
}
