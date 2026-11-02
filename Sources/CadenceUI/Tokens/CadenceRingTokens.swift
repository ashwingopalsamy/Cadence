// Day ring tokens (docs/SPEC.md section 5.2), from the Blueprint's ring. Lengths are in a 120 unit square that
// scales to the ring's size; angles are degrees clockwise from twelve o'clock.
import Foundation

public enum CadenceRingTokens {
    public static let viewBox: CGFloat = 120
    public static let segmentRadius: CGFloat = 50
    public static let segmentWidth: CGFloat = 8
    public static let segmentGap: CGFloat = 6
    public static let topGap: CGFloat = 14
    public static let dash: CGFloat = 2.4
    public static let dashGap: CGFloat = 2.1
    public static let hairline: CGFloat = 0.9
    public static let openOpacity: CGFloat = 0.13
    public static let emptyOpacity: CGFloat = 0.12

    public static let beadRadius: CGFloat = 37
    public static let beadSize: CGFloat = 3.4
    public static let beadSizeCompact: CGFloat = 4.2
    public static let reviewStroke: CGFloat = 1.4
    public static let beadStart: CGFloat = 13
    public static let beadStep: CGFloat = 13
    public static let beadFamilyGap: CGFloat = 7
    /// The degrees beads may fill before they tighten to fit.
    public static let beadSweep: CGFloat = 326
    public static let beadsPerFamily = 24
    /// AI is a tool you used, not an outcome, so it never crowds the ring.
    public static let aiBeads = 3

    public static let figure: CGFloat = 17
    public static let figureCompact: CGFloat = 21
    /// The caption shows where this many box units reach its point size, which keeps it above the type floor.
    public static let captionFit: CGFloat = 6.6
}
