// Today's fixed geometry (docs/SPEC.md section 6.4), taken from the approved prototype's coach.css. Anything the shared
// tokens already name comes from them; the rest is named here once, so no view carries a bare number.
import SwiftUI

/// The three designed widths and the compact layout (section 4.6).
public enum TodayWidth: Sendable, Equatable {
    /// Full and 900: the plan beside the metrics, Found today beside Log something.
    case wide
    /// 680: one column, a smaller headline, a smaller Tempo.
    case narrow
    /// Below 480: text wraps instead of truncating, and Tempo steps aside.
    case compact

    public static func of(_ width: CGFloat) -> TodayWidth {
        if width < CadenceSize.compactWidth { return .compact }
        return width <= TodayGeometry.stackWidth ? .narrow : .wide
    }
}

enum TodayGeometry {
    /// At or below this window width the cards stack (the prototype's `@container app (max-width:800px)`).
    static let stackWidth: CGFloat = 800
    static let columns = 12
    static let gap = CadenceSpace.s12

    // The hero.
    static let heroTop = CadenceSpace.s16
    static let heroSide = CadenceSpace.s24
    static let heroSideCompact = CadenceSpace.s16
    /// Without a chart the hero is this tall; with the band it is as tall as its fixed slots.
    static let heroMinHeight: CGFloat = 212
    static let headlineMargin = CadenceSpace.s4
    /// The empty chart slot, and the learning dots with their caption.
    static let emptyChart = CadenceSpace.s48
    static let sentenceMaxWidth: CGFloat = 544
    static let tempoWide: CGFloat = 150
    static let tempoNarrow: CGFloat = 96
    static let tempoTop = CadenceSpace.s8
    static let tempoTrailingWide: CGFloat = 112
    static let tempoTrailingNarrow = CadenceSpace.s16

    // The forest world's sky.
    static let stars = 18
    static let starSize: CGFloat = 3
    static let starOpacity = 0.7
    /// Stars sit in the top part of the hero only.
    static let starField = 0.44

    // The band.
    static let bandHeight: CGFloat = 148
    static let bandLegend: CGFloat = 28
    static let bandHeaderGap = CadenceSpace.s8
    static let bandInset = CadenceSpace.s8
    static let bandTopInset = CadenceSpace.s12
    static let bandFloor = 2.5
    static let bandCeiling = 11.0
    static let bandHeadroom = 0.5
    static let bandTicks = [4, 8, 12]
    static let bandTickInset: CGFloat = 5
    static let bandTickOpacity = 0.9
    static let bandLine: CGFloat = 2.2
    static let dot: CGFloat = 12
    static let dotStroke: CGFloat = 2
    static let todayMark: CGFloat = 20
    static let todayStroke: CGFloat = 4
    static let pendingMark: CGFloat = 16
    static let pendingStroke: CGFloat = 2.5
    static let dash: [CGFloat] = [4, 3]
    static let bracketWidth: CGFloat = 6
    static let bracketOpacity = 0.38
    static let todayLabelTrailing: CGFloat = 28
    static let todayLabelRise: CGFloat = 36
    static let todayLabelPad = CadenceSpace.s4
    /// The today mark is filled white so it reads on every world.
    static let todayFill = Color.white

    // Learning dots.
    static let learnDot: CGFloat = 22
    static let learnRing: CGFloat = 2

    // Cards.
    static let cardPadding = CadenceSpace.s16
    static let failurePaddingV = CadenceSpace.s20
    static let failurePaddingH = CadenceSpace.s24
    static let pebble: CGFloat = 12
    static let pebbleDash: CGFloat = 1.5
    static let tick: CGFloat = 20
    static let tickStroke: CGFloat = 2
    /// The focus ring on Today's buttons, as on every other surface.
    static let focusRing = CadenceSpace.s2
    /// The page's ring sits this far outside the hero card.
    static let focusGap = CadenceSpace.s4
    static let familyDot: CGFloat = 9
    static let blockColumns = 8
    static let blockRadius = CadenceSpace.s4
    static let spanBar: CGFloat = 16
    static let spanStart = 0.07
    static let spanMax = 0.84
    static let timeColumn: CGFloat = 40
    static let lateTint = 0.18
    static let droppedTint = 0.3
    static let fieldButtonTint = 0.10
    static let onWorldTint = 0.14
    static let foundShown = 5
}
