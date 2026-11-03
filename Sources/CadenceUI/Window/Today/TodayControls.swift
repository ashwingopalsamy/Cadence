// The small parts Today is built from: capsule buttons, the log field, a task row, a found row and the card slots
// (docs/SPEC.md sections 6.1, 6.4 and 6.5). Content is matte; depth comes from colour, never a shadow.
import CadenceCore
import SwiftUI

/// Capsule buttons: primary in `ink` on `canvas`, quiet on `track`, the focus ring in `focus` (section 6.1).
struct CapsuleButtonStyle: ButtonStyle {
    var quiet: Bool
    var height: CGFloat = CadenceSize.controlPrimary

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(configuration: configuration, quiet: quiet, height: height)
    }
}

private struct CapsuleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let quiet: Bool
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .cadenceType(CadenceType.body)
            .fontWeight(.bold)
            .lineLimit(1)
            .padding(.horizontal, CadenceSpace.s16)
            .frame(height: height)
            .foregroundStyle(quiet ? CadenceColor.ink.color : CadenceColor.canvas.color)
            .background(Capsule().fill(quiet ? CadenceColor.track.color : CadenceColor.ink.color))
            .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: TodayGeometry.focusRing))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(CadenceMotion.resolved(CadenceMotion.press.animation, reduceMotion: reduceMotion), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A plain button whose whole label is the target, with the focus ring around it. A label that draws its own pill
/// asks for a capsule ring.
struct RowButtonStyle: ButtonStyle {
    var capsule = false

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, capsule: capsule)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let capsule: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        let ring = focused ? CadenceColor.focus.color : Color.clear
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .overlay {
                if capsule {
                    Capsule().strokeBorder(ring, lineWidth: TodayGeometry.focusRing)
                } else {
                    RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous).strokeBorder(ring, lineWidth: TodayGeometry.focusRing)
                }
            }
    }
}

/// The quiet pill that switches a chart and its table twin.
struct TwinToggle: View {
    @Binding var showsTable: Bool
    var ink: Color = CadenceColor.ink3.color
    var ground: Color = CadenceColor.track.color

    var body: some View {
        Button { showsTable.toggle() } label: {
            Text(showsTable ? String(localized: "Chart") : String(localized: "Table"))
                .cadenceType(CadenceType.label)
                .foregroundStyle(ink)
                .padding(.horizontal, CadenceSpace.s8)
                .frame(height: CadenceSize.chip)
                .background(Capsule().fill(ground))
        }
        .buttonStyle(RowButtonStyle(capsule: true))
        .focusEffectDisabled()
        .accessibilityLabel(showsTable ? String(localized: "Show the chart") : String(localized: "Show the table"))
    }
}

/// The four card slots, always in this order, so neighbouring cards share lines (section 6.4).
struct CardSlots: View {
    var label: String
    var sentence: String?
    var value: [MetricPart]
    var comparison: String?
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardLabel(label)
            Text(sentence ?? " ")
                .cadenceType(CadenceType.sentence)
                .foregroundStyle(CadenceColor.ink.color)
                .lineLimit(compact ? nil : 1)
                .frame(minHeight: CadenceSize.sentenceSlot, alignment: .leading)
                .padding(.top, CadenceSpace.s4)
            Numeral(parts: value)
                .frame(height: CadenceSize.numberSlot, alignment: .leading)
            Text(comparison ?? " ")
                .cadenceType(CadenceType.comparison)
                .foregroundStyle(CadenceColor.ink3.color)
                .lineLimit(compact ? nil : 1)
                .frame(minHeight: CadenceSize.comparisonSlot, alignment: .leading)
        }
    }
}

struct CardLabel: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .cadenceType(CadenceType.label)
            .foregroundStyle(CadenceColor.ink3.color)
            .lineLimit(1)
            .frame(height: CadenceSize.labelSlot, alignment: .leading)
    }
}

/// Heavy rounded tabular numbers with small units (section 6.3).
struct Numeral: View {
    var parts: [MetricPart]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CadenceSpace.s8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                HStack(alignment: .firstTextBaseline, spacing: CadenceSpace.s4) {
                    Text(part.number).cadenceType(CadenceType.numeral)
                    if !part.unit.isEmpty {
                        Text(part.unit).cadenceType(CadenceType.numeralUnit)
                    }
                }
            }
        }
        .foregroundStyle(CadenceColor.ink.color)
        .lineLimit(1)
        .fixedSize()
    }
}

/// One plan task (section 6.5): open, done, slipped with its reason, dropped with its glyph. Done rows stay in place.
struct TaskRowView: View {
    var title: String
    var ticket: String?
    var status: TaskStatus
    var note: String?
    var editable: Bool
    var width: TodayWidth
    var onTick: () -> Void

    var body: some View {
        Button(action: onTick) {
            HStack(spacing: CadenceSpace.s12) {
                TickGlyph(status: status)
                Text(title)
                    .cadenceType(CadenceType.body)
                    .foregroundStyle(titleColor)
                    .strikethrough(status == .dropped, color: CadenceColor.ink3.color)
                    .lineLimit(width == .compact ? nil : 1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let ticket, width != .compact {
                    Text(ticket)
                        .cadenceType(CadenceType.figure)
                        .foregroundStyle(CadenceColor.ink2.color)
                        .padding(.horizontal, CadenceSpace.s6)
                        .frame(height: CadenceSize.ticket)
                        .background(RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous).fill(CadenceColor.track.color))
                        .fixedSize()
                }
                if let note, width != .compact {
                    Text(note)
                        .cadenceType(CadenceType.comparison)
                        .fontWeight(.semibold)
                        .foregroundStyle(CadenceColor.ink3.color)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            // Compact rows wrap: the padding sits inside the 40-point minimum, as in the prototype.
            .padding(.vertical, width == .compact ? CadenceSpace.s8 : 0)
            .frame(minHeight: CadenceSize.taskRow)
        }
        .buttonStyle(RowButtonStyle())
        .focusEffectDisabled()
        .disabled(!editable || status != .open)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(TaskWords.status(status))\(note.map { ", \($0)" } ?? "")")
        .accessibilityAddTraits(status == .done ? [.isButton, .isSelected] : .isButton)
    }

    private var titleColor: Color {
        switch status {
        case .done: CadenceColor.ink2.color
        case .dropped: CadenceColor.ink3.color
        default: CadenceColor.ink.color
        }
    }
}

/// Task states have their own glyphs, so identity is never colour alone (section 6.7).
struct TickGlyph: View {
    var status: TaskStatus
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let size = TodayGeometry.tick
        let stroke = CadenceIcon.stroke(TodayGeometry.tickStroke, contrast)
        ZStack {
            switch status {
            case .done:
                Circle().fill(CadenceColor.brand.color)
                Image(systemName: "checkmark").font(.system(size: CadenceIcon.small - CadenceSpace.s2, weight: CadenceIcon.weight(.heavy, contrast)))
                    .foregroundStyle(CadenceColor.onBrand.color)
            case .dropped:
                Circle().fill(CadenceColor.track.color)
                Image(systemName: "xmark").font(.system(size: CadenceIcon.small - CadenceSpace.s4, weight: CadenceIcon.weight(.bold, contrast)))
                    .foregroundStyle(CadenceColor.ink3.color)
            case .slipped:
                Circle().strokeBorder(CadenceColor.ink3.color, style: StrokeStyle(lineWidth: stroke, dash: TodayGeometry.dash))
            case .open, .moved:
                Circle().strokeBorder(CadenceColor.ink3.color, lineWidth: stroke)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One found item (section 4.6): time, the family's colour, the title, "After wrap-up", and the origin.
struct FoundRowView: View {
    var time: String
    var family: Family
    var title: String
    var late: Bool
    var origin: Origin
    var width: TodayWidth
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColour

    var body: some View {
        HStack(spacing: CadenceSpace.s8) {
            Text(time)
                .cadenceType(CadenceType.figure)
                .foregroundStyle(CadenceColor.ink3.color)
                .frame(width: TodayGeometry.timeColumn, alignment: .leading)
            FamilyDot(family: family, size: TodayGeometry.familyDot)
            // Differentiate Without Colour: the kind of work says its name too (section 6.7).
            if withoutColour {
                Text(Self.familyName(family))
                    .cadenceType(CadenceType.label)
                    .foregroundStyle(CadenceColor.ink2.color)
                    .fixedSize()
            }
            HStack(spacing: CadenceSpace.s6) {
                Text(title)
                    .cadenceType(CadenceType.body)
                    .foregroundStyle(CadenceColor.ink.color)
                    .lineLimit(width == .compact ? nil : 1)
                if late {
                    Text("After wrap-up")
                        .cadenceType(CadenceType.label)
                        .foregroundStyle(CadenceColor.ink.color)
                        .padding(.horizontal, CadenceSpace.s6)
                        .background(Capsule().fill(CadenceColor.brand.color.opacity(TodayGeometry.lateTint)))
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if width != .compact {
                Text(Self.originName(origin))
                    .cadenceType(CadenceType.label)
                    .foregroundStyle(CadenceColor.ink3.color)
                    .fixedSize()
                    .help(Self.originHelp(origin))
            }
        }
        .frame(minHeight: CadenceSize.foundRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(time), \(Self.familyName(family)), \(title)\(late ? String(localized: ", after wrap-up") : ""), \(Self.originHelp(origin).lowercased())")
    }

    static func familyName(_ family: Family) -> String {
        switch family {
        case .delivery: String(localized: "Delivery")
        case .review: String(localized: "Review")
        case .initiative: String(localized: "Initiative")
        case .ownership: String(localized: "Ownership")
        case .leadership: String(localized: "Leadership")
        case .ai: String(localized: "AI")
        case .presence: String(localized: "Presence")
        }
    }

    static func originName(_ origin: Origin) -> String { origin.rawValue }

    static func originHelp(_ origin: Origin) -> String {
        switch origin {
        case .collected: String(localized: "Collected by a source you approved")
        case .observed: String(localized: "Observed on this Mac")
        case .agent: String(localized: "Proposed by an agent")
        case .selfReported: String(localized: "Logged by you")
        }
    }
}

/// One line is enough: the log field (section 4.6).
struct LogField: View {
    var placeholder: String
    var onLog: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: CadenceSpace.s8) {
            TextField("Log something", text: $text, prompt: Text(placeholder).foregroundStyle(CadenceColor.ink3.color))
                .textFieldStyle(.plain)
                .cadenceType(CadenceType.body)
                .foregroundStyle(CadenceColor.ink.color)
                .labelsHidden()
                .onSubmit(submit)
                .accessibilityLabel("Log something")
            Button(action: submit) {
                Text("Log")
                    .cadenceType(CadenceType.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(CadenceColor.ink.color)
                    .padding(.horizontal, CadenceSpace.s12)
                    .frame(height: CadenceSize.controlSecondary)
                    .background(
                        RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
                            .fill(CadenceColor.ink.color.opacity(TodayGeometry.fieldButtonTint)))
            }
            .buttonStyle(RowButtonStyle())
            .focusEffectDisabled()
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, CadenceSpace.s12)
        .padding(.trailing, CadenceSpace.s4)
        .frame(height: CadenceSize.controlPrimary)
        .background(RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous).fill(CadenceColor.track.color))
    }

    private func submit() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        onLog(line)
        text = ""
    }
}

/// A hint under a card: 12/16 in `ink-3`.
struct Hint: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .cadenceType(CadenceType.comparison)
            .foregroundStyle(CadenceColor.ink3.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// A matte card that fills its column's height, with the card's padding.
    func todayCard(padding: EdgeInsets = EdgeInsets(
        top: TodayGeometry.cardPadding, leading: TodayGeometry.cardPadding, bottom: TodayGeometry.cardPadding,
        trailing: TodayGeometry.cardPadding)
    ) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cadenceCard()
    }
}
