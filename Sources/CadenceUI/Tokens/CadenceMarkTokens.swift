// Menu-bar mark tokens (docs/SPEC.md section 4.1). Points inside the 18 pt status item, y down, from the approved
// prototype's barMark. Arcs are degrees clockwise from twelve o'clock.
import Foundation

public enum CadenceMarkTokens {
    /// The status item's fixed length, and the side of the square the mark is drawn in.
    public static let side: CGFloat = 18
    public static let centre = CGPoint(x: 9, y: 9)

    public static let ringRadius: CGFloat = 6.9
    /// The water sits inside this radius, so a clear gap separates it from the ring.
    public static let waterRadius: CGFloat = 5.3
    public static let stroke: CGFloat = 1.2
    public static let strokeThick: CGFloat = 1.7
    /// Increase Contrast thickens the ring, and the thick ring by as much, so the two stay apart.
    public static let strokeHighContrast: CGFloat = 1.5
    public static let strokeThickHighContrast: CGFloat = 2.0
    /// Notch, ears and half: round caps on the ring's own radius.
    public static let accentStroke: CGFloat = 2
    public static let dash: [CGFloat] = [2.3, 1.95]
    /// A near-zero dash with round caps draws a dot as wide as the stroke.
    public static let dots: [CGFloat] = [0.01, 2.4]

    public static let discRadius: CGFloat = 7.5
    public static let hollowCutRadius: CGFloat = 2.2
    public static let hollowCutStroke: CGFloat = 1.3
    /// The "!" cut: a rounded bar and a dot.
    public static let bangBar = CGRect(x: 8.25, y: 4.6, width: 1.5, height: 5.4)
    public static let bangBarCorner: CGFloat = 0.75
    public static let bangDot = CGPoint(x: 9, y: 12.6)
    public static let bangDotRadius: CGFloat = 0.9

    public static let centreDotRadius: CGFloat = 2.2
    public static let hollowCentreRadius: CGFloat = 2
    public static let hollowCentreStroke: CGFloat = 1.3

    public static let notch: ClosedRange<CGFloat> = -12...48
    public static let earLeft: ClosedRange<CGFloat> = -78...(-38)
    public static let earRight: ClosedRange<CGFloat> = 38...78
    public static let half: ClosedRange<CGFloat> = 180...359.9
    /// The ring open at the top (paused), and broken at the upper right (a source behind).
    public static let openTop: ClosedRange<CGFloat> = 28...332
    public static let broken: ClosedRange<CGFloat> = 72...390

    /// The neutral ring in ink, at rest and under the pointer. Increase Contrast takes it to full ink.
    public static let neutralRing: CGFloat = 0.55
    public static let neutralRingHover: CGFloat = 0.9
    public static let faint: CGFloat = 0.45
    /// Water with nothing resolved: a thin band at the bottom of the water.
    public static let meniscus: CGFloat = 1.6
    /// Water on a quieter day, and while capture is paused.
    public static let softQuieter: Double = 0.65
    public static let softPaused: Double = 0.4

    /// Attention breathes down to this opacity at the middle of each breath.
    public static let breathFloor: CGFloat = 0.28
    /// The disc grows from this scale and opacity as it seals.
    public static let sealScale: CGFloat = 0.7
    public static let sealOpacity: CGFloat = 0.4
    /// A tick lifts the water's brightness to `liftStart`, eases to `liftHold` by `liftHoldAt` of the rise, then settles.
    public static let liftStart: CGFloat = 1.35
    public static let liftHold: CGFloat = 1.15
    public static let liftHoldAt: Double = 0.7
}
