// The capture bar (docs/SPEC.md sections 4.3, 4.8 and 6): a floating glass bar like Spotlight. One line in, chips
// from Core's parser under it, saved as logged by you. Glass is floating chrome; Reduce Transparency makes it solid.
import AppKit
import CadenceCore
import SwiftUI

public struct CaptureBarView: View {
    /// Sizes from the approved prototype (`.capturebar`, `.capline`, `.capchips`, `.chip`), all on the type and
    /// space scales of section 6.
    enum Layout {
        static let width: CGFloat = 620
        static let icon: CGFloat = 26
        static let padding = CadenceSpace.s12
        static let lineGap = CadenceSpace.s8
        static let lineInset = EdgeInsets(top: CadenceSpace.s2, leading: CadenceSpace.s4, bottom: CadenceSpace.s2, trailing: CadenceSpace.s4)
        static let chipGap = CadenceSpace.s6
        static let chipRowHeight = CadenceSize.chip + CadenceSpace.s2
        static let chipInset = EdgeInsets(top: CadenceSpace.s6, leading: CadenceSpace.s4, bottom: 0, trailing: CadenceSpace.s4)
        static let chipPadding = CadenceSpace.s8
        static let chipInner = CadenceSpace.s4
        static let familyDot = CadenceSpace.s8
        static let keyPadding = CadenceSpace.s6
        static let statusPadding = EdgeInsets(top: CadenceSpace.s8, leading: CadenceSpace.s12, bottom: CadenceSpace.s8, trailing: CadenceSpace.s12)
        static let noteInset = EdgeInsets(top: CadenceSpace.s8, leading: CadenceSpace.s4, bottom: 0, trailing: CadenceSpace.s4)
        static let choicePadding = CadenceSpace.s12
        static let focusRing = CadenceSpace.s2
        /// The prototype tints a failure and a hovered quiet control this far toward their colour.
        static let tint = 0.13
        static let hoverTint = 0.12
        static let pressScale = 0.97

        static let field = TypeToken(name: "capture field", face: .sfPro, size: 18, lineHeight: 24, weight: 500, tracking: 0, sample: "")
        static let chipValue = TypeToken(name: "chip", face: .sfPro, size: 12, lineHeight: 16, weight: 600, tracking: 0, sample: "")
        static let chipKey = TypeToken(name: "chip key", face: .sfPro, size: 11, lineHeight: 16, weight: 500, tracking: 0, sample: "")
        static let status = TypeToken(name: "status", face: .sfPro, size: 13, lineHeight: 20, weight: 600, tracking: 0, sample: "")
        static let statusBody = TypeToken(name: "status body", face: .sfPro, size: 13, lineHeight: 20, weight: 500, tracking: 0, sample: "")
        /// The prototype sets keys in the mono face, but Geist Mono has no arrow glyphs, so keys use SF Pro.
        static let key = TypeToken(name: "key", face: .sfPro, size: 11, lineHeight: 16, weight: 600, tracking: 0, sample: "")
        /// The chips' row inside the bar's padding and its own inset, so wrapping is measured against the real width.
        static var chipWidth: CGFloat { width - padding * 2 - chipInset.leading - chipInset.trailing }
    }

    @Bindable var model: CaptureBarModel
    private let icon: (() -> AnyView)?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// `icon` draws the app icon in its 26-point slot; without it the slot keeps its place.
    public init(model: CaptureBarModel, icon: (() -> AnyView)? = nil) {
        self.model = model
        self.icon = icon
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Layout.lineGap) {
                iconSlot
                CaptureField(model: model, token: Layout.field)
                    .frame(height: Layout.field.lineHeight + CadenceSpace.s8)
                CaptureKeyHint(text: "↩")
            }
            .padding(Layout.lineInset)

            chipRow
                .padding(Layout.chipInset)

            if let message = model.message {
                messageView(message).padding(.top, CadenceSpace.s8)
            } else if let duplicate = model.duplicate {
                duplicateOffer(duplicate).padding(.top, CadenceSpace.s8)
            }

            Text(model.editingEntry == nil ? CaptureAdapter.hint : String(localized: "Editing your last entry. Saving replaces it."))
                .cadenceType(CadenceType.comparison)
                .foregroundStyle(CadenceColor.ink3.color)
                .padding(Layout.noteInset)
        }
        .padding(Layout.padding)
        .frame(width: Layout.width, alignment: .leading)
        .background { surface }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture")
        .onChange(of: model.message) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(Self.text(of: message)).post()
        }
        .onChange(of: model.duplicate?.id) { _, id in
            guard id != nil, let entry = model.duplicate else { return }
            AccessibilityNotification.Announcement(CaptureAdapter.duplicateMessage(entry)).post()
        }
    }

    // MARK: Parts

    /// Liquid Glass, or the same panel colour made opaque under Reduce Transparency (section 6.1).
    @ViewBuilder private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: CadenceRadius.card, style: .continuous)
        let shadow = CadenceShadow.floating
        Group {
            if reduceTransparency {
                shape.fill(Color(nsColor: CadenceColor.panel.nsColor.withAlphaComponent(1)))
            } else {
                shape.fill(.clear).glassEffect(.regular, in: .rect(cornerRadius: CadenceRadius.card))
            }
        }
        .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
    }

    private var iconSlot: some View {
        Group {
            if let icon { icon() } else { Color.clear }
        }
        .frame(width: Layout.icon, height: Layout.icon)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var chipRow: some View {
        let chips = model.chips
        Group {
            if chips.isEmpty {
                Text(CaptureAdapter.chipsHint)
                    .cadenceType(CadenceType.comparison)
                    .foregroundStyle(CadenceColor.ink3.color)
                    .frame(minHeight: Layout.chipRowHeight, alignment: .center)
            } else {
                ChipFlow(spacing: Layout.chipGap) {
                    ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                        if model.editingChip == index {
                            ChipEditor(model: model, chip: chip)
                        } else {
                            Button { model.activate(index) } label: { ChipLabel(chip: chip) }
                                .buttonStyle(ChipStyle(focused: model.focusedChip == index))
                                .accessibilityLabel(Self.voice(of: chip))
                                .accessibilityHint(chip.cycles ? String(localized: "Changes the kind.") : String(localized: "Edits the \(chip.label)."))
                        }
                    }
                }
                .frame(width: Layout.chipWidth, alignment: .leading)
                .frame(minHeight: Layout.chipRowHeight, alignment: .leading)
            }
        }
        .cadenceAnimation(CadenceMotion.press.animation, value: chips.map(\.id))
    }

    private func messageView(_ message: CaptureBarModel.Message) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch message {
            case .empty:
                Text(CaptureAdapter.emptyMessage).cadenceType(Layout.status)
            case .failed(let failure):
                Text(failure.summary + ".").cadenceType(Layout.status)
                Text("Your line is still here. \(failure.detail)")
                    .cadenceType(Layout.statusBody)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(CadenceColor.warn.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Layout.statusPadding)
        .background(
            RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous)
                .fill(CadenceColor.warn.color.opacity(Layout.tint)))
        .padding(.horizontal, CadenceSpace.s4)
    }

    private func duplicateOffer(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(CaptureAdapter.duplicateMessage(entry)).cadenceType(Layout.status)
            Text(CaptureAdapter.linkReason).cadenceType(Layout.statusBody)
            HStack(spacing: CadenceSpace.s8) {
                Button(CaptureAdapter.linkThem) { model.linkThem() }
                    .buttonStyle(ChoiceStyle())
                Button(CaptureAdapter.logSeparately) { Task { await model.logSeparately() } }
                    .buttonStyle(ChoiceStyle())
            }
            .padding(.top, CadenceSpace.s6)
        }
        .foregroundStyle(CadenceColor.ink.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Layout.statusPadding)
        .background(
            RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous).fill(CadenceColor.track.color))
        .padding(.horizontal, CadenceSpace.s4)
        .accessibilityElement(children: .contain)
    }

    static func text(of message: CaptureBarModel.Message) -> String {
        switch message {
        case .empty: CaptureAdapter.emptyMessage
        case .failed(let failure): String(localized: "\(failure.summary). Your line is still here. \(failure.detail)")
        }
    }

    static func voice(of chip: CaptureChip) -> String {
        [chip.label.capitalized, chip.value, chip.detail].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Chips

struct ChipLabel: View {
    let chip: CaptureChip
    typealias Layout = CaptureBarView.Layout

    var body: some View {
        HStack(spacing: Layout.chipInner) {
            if let family = chip.family {
                FamilyDot(family: family, size: Layout.familyDot)
            }
            Text(chip.label)
                .cadenceType(Layout.chipKey)
                .foregroundStyle(CadenceColor.ink3.color)
            Text(chip.value)
                .cadenceType(chip.isFigure ? CadenceType.figure : Layout.chipValue)
                .foregroundStyle(CadenceColor.ink.color)
            if let detail = chip.detail {
                Text(detail)
                    .cadenceType(Layout.chipKey)
                    .foregroundStyle(CadenceColor.ink2.color)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, Layout.chipPadding)
        .frame(height: CadenceSize.chip)
    }
}

/// Rest on `track`, hover a step darker, pressed a touch smaller, focus in `focus` (section 6.5).
struct ChipStyle: ButtonStyle {
    var focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        Pressable(configuration: configuration, rest: CadenceColor.track, focused: focused)
    }
}

/// The quiet capsule of the duplicate offer: 32 high, `card` inside a status block.
struct ChoiceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pressable(
            configuration: configuration, rest: CadenceColor.card, focused: false,
            height: CadenceSize.controlSecondary, padding: CaptureBarView.Layout.choicePadding)
    }
}

/// A capsule control in rest, hover, pressed and focus. Hover lives in a view, where SwiftUI keeps its state.
private struct Pressable: View {
    typealias Layout = CaptureBarView.Layout
    let configuration: ButtonStyleConfiguration
    let rest: ColorToken
    let focused: Bool
    var height: CGFloat?
    var padding: CGFloat?

    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        styled
            .background(
                Capsule().fill(hover ? CadenceColor.ink.color.mix(with: rest.color, by: 1 - Layout.hoverTint) : rest.color))
            .overlay(Capsule().strokeBorder(CadenceColor.focus.color, lineWidth: focused ? Layout.focusRing : 0))
            .scaleEffect(configuration.isPressed && !reduceMotion ? Layout.pressScale : 1)
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .animation(CadenceMotion.resolved(CadenceMotion.press.animation, reduceMotion: reduceMotion), value: configuration.isPressed)
    }

    @ViewBuilder private var styled: some View {
        if let height, let padding {
            configuration.label
                .cadenceType(Layout.status)
                .foregroundStyle(CadenceColor.ink.color)
                .padding(.horizontal, padding)
                .frame(height: height)
        } else {
            configuration.label
        }
    }
}

/// A time, duration or other chip open for typing. ↩ keeps the change when the parser reads it; Esc drops it.
struct ChipEditor: View {
    @Bindable var model: CaptureBarModel
    let chip: CaptureChip
    @FocusState private var focused: Bool
    typealias Layout = CaptureBarView.Layout

    var body: some View {
        HStack(spacing: Layout.chipInner) {
            Text(chip.label)
                .cadenceType(Layout.chipKey)
                .foregroundStyle(CadenceColor.ink3.color)
            TextField(chip.role == .time ? "14:30" : chip.value, text: $model.editText)
                .textFieldStyle(.plain)
                .cadenceType(chip.isFigure ? CadenceType.figure : Layout.chipValue)
                .foregroundStyle(CadenceColor.ink.color)
                .fixedSize()
                .focused($focused)
                .onSubmit { model.commitEdit() }
                .onExitCommand { model.escape() }
                .accessibilityLabel("Edit the \(chip.label)")
        }
        .padding(.horizontal, Layout.chipPadding)
        .frame(height: CadenceSize.chip)
        .background(Capsule().fill(CadenceColor.card.color))
        .overlay(Capsule().strokeBorder(CadenceColor.focus.color, lineWidth: Layout.focusRing))
        .onAppear { focused = true }
    }
}

/// A key cap on `track`, 20 high (section 6.4).
struct CaptureKeyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .cadenceType(CaptureBarView.Layout.key)
            .foregroundStyle(CadenceColor.ink2.color)
            .padding(.horizontal, CaptureBarView.Layout.keyPadding)
            .frame(height: CadenceSize.ticket)
            .background(RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous).fill(CadenceColor.track.color))
            .accessibilityLabel("Return saves")
    }
}

/// Chips in rows that wrap, left to right.
struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - The field

/// The one-line field. AppKit, so Tab, ⇧Tab, ⌫, ↑, ↩, ⌘↩ and Esc reach the bar before the field editor acts on them.
struct CaptureField: NSViewRepresentable {
    @Bindable var model: CaptureBarModel
    let token: TypeToken

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.font = token.nsFont
        field.textColor = CadenceColor.ink.nsColor
        field.placeholderAttributedString = NSAttributedString(
            string: CaptureAdapter.placeholder,
            attributes: [.font: token.nsFont, .foregroundColor: CadenceColor.ink3.nsColor])
        field.setAccessibilityLabel(String(localized: "What did you do?"))
        field.delegate = context.coordinator
        field.stringValue = model.draft.text
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.model = model
        let editor = field.currentEditor() as? NSTextView
        if field.stringValue != model.draft.text, editor?.hasMarkedText() != true {
            field.stringValue = model.draft.text
            editor?.moveToEndOfDocument(nil)
        }
        if context.coordinator.focusRequest != model.fieldFocusRequest {
            context.coordinator.focusRequest = model.fieldFocusRequest
            DispatchQueue.main.async { field.focusWhenReady() }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: CaptureBarModel
        var focusRequest = -1

        init(model: CaptureBarModel) {
            self.model = model
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.draft.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let empty = textView.string.isEmpty
            let command = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if let chip = model.focusedChip, !command {
                    model.activate(chip)
                } else {
                    Task { await model.submit(keepOpen: command) }
                }
                return true
            case Selector(("noop:")):
                // ⌘↩ has no binding of its own, so it arrives as noop.
                guard command, NSApp.currentEvent?.specialKey == .carriageReturn else { return false }
                Task { await model.submit(keepOpen: true) }
                return true
            case #selector(NSResponder.insertTab(_:)):
                model.moveFocus(backward: false)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                model.moveFocus(backward: true)
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                guard model.focusedChip != nil || empty else { return false }
                return model.deleteBackward(fieldIsEmpty: empty)
            case #selector(NSResponder.moveUp(_:)):
                return empty && model.editLast()
            case #selector(NSResponder.cancelOperation(_:)):
                model.escape()
                return true
            default:
                return false
            }
        }
    }
}

/// Takes the caret as soon as it is in a window.
final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusWhenReady()
    }

    func focusWhenReady() {
        guard let window, window.firstResponder !== currentEditor() else { return }
        window.makeFirstResponder(self)
        currentEditor()?.moveToEndOfDocument(nil)
    }
}
