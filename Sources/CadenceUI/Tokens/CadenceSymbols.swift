// The SF Symbols map (docs/SPEC.md section 6.2). No custom icons beyond the mark, Tempo and the app icon; no emoji.
import CadenceCore
import SwiftUI

public enum CadenceSymbols {
    /// A presence span shows `sunrise` at its start and `sunset` at its end.
    public static let dayStart = "sunrise"
    public static let dayEnd = "sunset"

    public static func name(for kind: EntryKind) -> String {
        switch kind {
        case .prOpened: "arrow.triangle.pull"
        case .prMerged: "arrow.triangle.merge"
        case .shipped: "shippingbox"
        case .workDone: "checkmark.circle"
        case .reviewGiven: "checkmark.bubble"
        case .docReviewed: "eye"
        case .initiativeStarted, .initiativeProgress: "flag"
        case .incidentHandled: "bolt.horizontal"
        case .oncallShift: "antenna.radiowaves.left.and.right"
        case .discussionRaised: "bubble.left.and.text.bubble.right"
        case .decisionChallenged: "exclamationmark.bubble"
        case .meetingLed: "person.wave.2"
        case .mentoring: "person.line.dotted.person"
        case .docWritten: "doc.text"
        case .genaiSession, .genaiUsage: "terminal"
        case .presenceSpan: dayStart
        case .meetingAttended: "person.2"
        case .note: "text.alignleft"
        }
    }
}

extension Image {
    /// A symbol in the house style: hierarchical, regular at 13 to 15 pt, medium in the panel.
    /// Increase Contrast takes it one weight heavier (section 6.7).
    public func cadenceIcon(size: CGFloat = CadenceIcon.small, inPanel: Bool = false) -> some View {
        CadenceIconView(image: self, size: size, weight: inPanel ? CadenceIcon.panelWeight : CadenceIcon.weight)
    }
}

private struct CadenceIconView: View {
    let image: Image
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        image.symbolRenderingMode(.hierarchical)
            .font(.system(size: size, weight: CadenceIcon.weight(weight, contrast)))
    }
}
