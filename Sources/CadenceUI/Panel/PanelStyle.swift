// The panel's own roles, built from the tokens of docs/SPEC.md section 6 and sized as the approved prototype's
// `.panel` rules (coach.css). Sizes come only from the type scale of section 6.3; everything else is a token.
import AppKit
import SwiftUI

enum PanelType {
    /// The day's headline: 15/20 semibold, one line.
    static let headline = TypeToken(name: "panel headline", face: .sfPro, size: 15, lineHeight: 20, weight: 600, tracking: 0, sample: "Right in your rhythm.")
    /// The short line under it.
    static let line = CadenceType.comparison
    /// "Today's plan" and the count.
    static let head = CadenceType.label
    /// A task title, and "No plan yet.".
    static let row = TypeToken(name: "panel row", face: .sfPro, size: 13, lineHeight: 20, weight: 400, tracking: 0, sample: "Write the ADR")
    /// Small text buttons: Undo, Resume, Sources, Working after all, "2 more in Today", the footer.
    static let small = TypeToken(name: "panel small", face: .sfPro, size: 12, lineHeight: 16, weight: 600, tracking: 0, sample: "Open Cadence")
    /// Undo, Resume and Sources read stronger than the text beside them.
    static let smallStrong = TypeToken(name: "panel small strong", face: .sfPro, size: 12, lineHeight: 16, weight: 700, tracking: 0, sample: "Undo")
    /// The one action.
    static let action = TypeToken(name: "panel action", face: .sfPro, size: 14, lineHeight: 20, weight: 700, tracking: 0, sample: "Plan your day")
    /// The log field.
    static let field = CadenceType.body
    /// Key hints such as ⌃⌥L. Geist Mono is only for tickets, times and hashes, so keys use the label face.
    static let key = CadenceType.label
}

enum PanelMetrics {
    static let width = CadenceSize.panelWidth
    static let padding = CadenceSpace.panelPadding
    /// Space between the header, the note, the plan and the log field.
    static let block = CadenceSpace.s12
    /// Rows reach this far into the padding, so their hover sits inside it.
    static let rowInset = CadenceSpace.s8
    static let row = CadenceSize.taskRow
    static let tick: CGFloat = CadenceSpace.s16 + CadenceSpace.s2
    static let tickStroke = CadenceSpace.s2
    static let tickGlyph = CadenceSpace.s8 + CadenceSpace.s2
    static let note = CadenceSize.controlSecondary
    static let field = CadenceSize.controlSecondary
    static let head = CadenceSize.chip
    static let smallButton = CadenceSize.chip
    static let undo = CadenceSize.ticket
    static let key = CadenceSize.ticket
    static let action = CadenceSize.controlPrimary
    static let footer = CadenceSize.controlToolbar
    static let focusRing = CadenceSpace.s2
    /// The `⌘↩` key on the dark action button: canvas at this strength, as the prototype's `.kbd.inv`.
    static let invertedKey = 0.22
    /// The dash of a slipped task's ring.
    static let slipDash: CGFloat = 3
    /// A tick ring grows this much under the pointer, as the prototype's `.tick` hover.
    static let hoverLift: CGFloat = 1.08
    /// A pressed button settles this small, as the prototype's `.btn:active`.
    static let pressScale: CGFloat = 0.97
    /// A disabled control keeps its place and fades.
    static let disabled = 0.45
}

extension ColorToken {
    /// The token with its alpha forced to 1, for the solid fallback under Reduce Transparency (section 6.2: the
    /// `panel` colour, opaque).
    var opaque: Color {
        let light = Self.resolve(light).withAlphaComponent(1)
        let dark = Self.resolve(dark).withAlphaComponent(1)
        return Color(
            nsColor: NSColor(name: NSColor.Name("\(name)-opaque")) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
    }
}

/// Floating chrome (section 6.1): Liquid Glass, or the solid `panel` colour under Reduce Transparency.
struct PanelChrome: ViewModifier {
    /// Snapshots draw offscreen, where there is nothing behind the glass, so they ask for the solid ground.
    var forceSolid = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CadenceRadius.card, style: .continuous)
        if reduceTransparency || forceSolid {
            content.background(shape.fill(CadenceColor.panel.opaque))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: CadenceRadius.card))
        }
    }
}
