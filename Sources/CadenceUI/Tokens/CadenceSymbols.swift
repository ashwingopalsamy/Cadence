// The SF Symbols map and family shapes (docs/SPEC.md section 6.2). No custom icons, no emoji.
import CadenceCore
import SwiftUI

public enum FamilyShape: String, Sendable {
    case circle, ring, diamond, square, triangle, smallDot, none
}

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

    public static func shape(for family: Family) -> FamilyShape {
        switch family {
        case .delivery: .circle
        case .review: .ring
        case .initiative: .diamond
        case .ownership: .square
        case .leadership: .triangle
        case .ai: .smallDot
        case .presence: .none
        }
    }
}

extension Image {
    /// A symbol in the house style: hierarchical, regular at 13 to 15 pt, medium in the Pocket.
    public func cadenceIcon(size: CGFloat = CadenceIcon.small, inPocket: Bool = false) -> some View {
        symbolRenderingMode(.hierarchical)
            .font(.system(size: size, weight: inPocket ? CadenceIcon.pocketWeight : CadenceIcon.weight))
    }
}
