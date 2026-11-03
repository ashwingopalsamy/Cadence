// The panel's small parts: Tempo's slot, a plan row and its tick, key hints, and the button styles
// (docs/SPEC.md sections 4.2, 6.4 and 6.5). Every part has rest, hover, pressed, focus and disabled.
import CadenceCore
import SwiftUI

/// Tempo at 44 points in the panel's header. The character is built by whoever owns Tempo, so the panel never
/// depends on how it is drawn.
public struct TempoSlot: View {
    private let character: (@MainActor () -> AnyView)?

    public init(_ character: (@MainActor () -> AnyView)?) {
        self.character = character
    }

    public var body: some View {
        Group {
            if let character { character() }
        }
        .frame(width: CadenceSize.panelTempo, height: CadenceSize.panelTempo)
        .accessibilityHidden(true)
    }
}

/// A key hint such as ⌃⌥L. Decorative: the action it names carries its own words.
struct KeyHint: View {
    let keys: String
    var inverted = false

    var body: some View {
        Text(keys)
            .cadenceType(PanelType.key)
            .foregroundStyle(inverted ? CadenceColor.canvas.color : CadenceColor.ink2.color)
            .padding(.horizontal, CadenceSpace.s6)
            .frame(height: PanelMetrics.key)
            .background(
                RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
                    .fill(inverted ? CadenceColor.canvas.color.opacity(PanelMetrics.invertedKey) : CadenceColor.track.color))
            .accessibilityHidden(true)
    }
}

/// The task glyph: a ring when open, filled with a check when done, dashed when slipped, a cross when dropped.
/// Every state has its own form, so none relies on colour.
struct TickMark: View {
    let status: TaskStatus
    var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let stroke = CadenceIcon.stroke(PanelMetrics.tickStroke, contrast)
        ZStack {
            switch status {
            case .done:
                Circle().fill(CadenceColor.ink2.color)
                glyph("checkmark", CadenceColor.card)
            case .dropped:
                Circle().fill(CadenceColor.track.color)
                glyph("xmark", CadenceColor.ink3)
            case .slipped:
                Circle().strokeBorder(
                    CadenceColor.ink3.color, style: StrokeStyle(lineWidth: stroke, dash: [PanelMetrics.slipDash]))
            case .open, .moved:
                Circle().strokeBorder(hover ? CadenceColor.ink.color : CadenceColor.ink3.color, lineWidth: stroke)
            }
        }
        .frame(width: PanelMetrics.tick, height: PanelMetrics.tick)
        .scaleEffect(hover && status == .open && !reduceMotion ? PanelMetrics.hoverLift : 1)
        .cadenceAnimation(CadenceMotion.tick.animation, value: status)
        .cadenceAnimation(CadenceMotion.press.animation, value: hover)
    }

    private func glyph(_ name: String, _ color: ColorToken) -> some View {
        Image(systemName: name)
            .font(.system(size: PanelMetrics.tickGlyph, weight: CadenceIcon.weight(.bold, contrast)))
            .foregroundStyle(color.color)
            .transition(.scale.combined(with: .opacity))
    }
}

/// One plan row, 40 points high and always one line. Done rows stay in place, dimmed.
struct PlanRow: View {
    let row: PanelContent.Row
    let focused: Bool
    let tick: () -> Void
    @State private var hover = false

    private var interactive: Bool { row.tickable || row.held }

    var body: some View {
        HStack(spacing: CadenceSpace.s8) {
            TickMark(status: row.status, hover: hover && interactive)
            Text(row.title)
                .cadenceType(PanelType.row)
                .strikethrough(row.status == .dropped)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PanelMetrics.rowInset)
        .frame(height: PanelMetrics.row)
        .contentShape(Rectangle())
        .background(PanelHighlight(on: interactive && (hover || focused), focused: focused))
        .onHover { hover = $0 }
        .onTapGesture { if interactive { tick() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(TaskWords.status(row.status))")
        .accessibilityAddTraits(interactive ? .isButton : [])
        .accessibilityAction { if interactive { tick() } }
    }

    private var titleColor: Color {
        switch row.status {
        case .done, .slipped: CadenceColor.ink2.color
        case .dropped: CadenceColor.ink3.color
        case .open, .moved: CadenceColor.ink.color
        }
    }

}

/// A task's state as VoiceOver says it, the same in the panel and in Today. Moved draws the open ring, so it reads
/// open; slipped keeps the word the wrap-up and the recap use.
enum TaskWords {
    static func status(_ status: TaskStatus) -> String {
        switch status {
        case .open, .moved: String(localized: "open")
        case .done: String(localized: "done")
        case .slipped: String(localized: "slipped")
        case .dropped: String(localized: "dropped")
        }
    }
}

/// The quiet fill behind a hovered or focused row, with the focus ring when the keyboard is on it.
struct PanelHighlight: View {
    let on: Bool
    var focused = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
        shape.fill(on ? CadenceColor.line.color : Color.clear)
            .overlay(shape.strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: PanelMetrics.focusRing))
    }
}

/// Small text buttons: Undo, Resume, Sources, Working after all, the footer and "2 more in Today".
struct PanelTextButtonStyle: ButtonStyle {
    var type = PanelType.small
    var height = PanelMetrics.smallButton
    var color = CadenceColor.ink2
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        PanelTextButton(configuration: configuration, type: type, height: height, color: color, fullWidth: fullWidth)
    }
}

private struct PanelTextButton: View {
    let configuration: ButtonStyleConfiguration
    let type: TypeToken
    let height: CGFloat
    let color: ColorToken
    let fullWidth: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .cadenceType(type)
            .foregroundStyle(hover || configuration.isPressed ? CadenceColor.ink.color : color.color)
            .lineLimit(1)
            .padding(.horizontal, CadenceSpace.s8)
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
            .frame(height: height)
            .background(PanelHighlight(on: hover || configuration.isPressed, focused: focused))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : PanelMetrics.disabled)
            .onHover { hover = $0 }
    }
}

/// The one action: a primary capsule in `ink` on the panel, the title left and `⌘↩` right.
struct PanelPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelPrimary(configuration: configuration)
    }
}

private struct PanelPrimary: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .padding(.leading, CadenceSpace.s16)
            .padding(.trailing, CadenceSpace.s6)
            .frame(maxWidth: .infinity)
            .frame(height: PanelMetrics.action)
            .foregroundStyle(CadenceColor.canvas.color)
            .background(Capsule().fill(CadenceColor.ink.color))
            .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: PanelMetrics.focusRing))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? PanelMetrics.pressScale : 1)
            .cadenceAnimation(CadenceMotion.press.animation, value: configuration.isPressed)
    }
}
