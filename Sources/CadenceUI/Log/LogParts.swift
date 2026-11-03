// The window's list parts, shared by the Log and the Inbox: the section head, the family dot, the origin badge, the
// ticket, the After wrap-up mark, the buttons and chips, the inline title field, and the empty state (docs/SPEC.md
// sections 6.4 and 6.5). Sizes follow the approved prototype's `.tabhead`, `.fchip`, `.entry`, `.tkt`, `.origin`,
// `.late`, `.btn`, `.choice`, `.inl` and `.empty` rules (coach.css), taken only from the type scale and the tokens. Every control has rest, hover,
// pressed, focus and disabled.
import CadenceCore
import SwiftUI

enum ListType {
    /// A day's heading in the Log: rounded 15/20 heavy.
    static let dayHead = TypeToken(name: "list day", face: .sfRounded, size: 15, lineHeight: 20, weight: 800, tracking: 0, sample: "Wed 28 Oct")
    /// A filter chip, a choice and a small primary button: 13/20 semibold.
    static let chip = TypeToken(name: "list chip", face: .sfPro, size: 13, lineHeight: 20, weight: 600, tracking: 0, sample: "Delivery")
    /// A small primary button such as Accept: 13/20 bold.
    static let smallAction = TypeToken(name: "list small action", face: .sfPro, size: 13, lineHeight: 20, weight: 700, tracking: 0, sample: "Accept")
    /// A full-size button such as Clear filters: 14/20 bold.
    static let action = TypeToken(name: "list action", face: .sfPro, size: 14, lineHeight: 20, weight: 700, tracking: 0, sample: "Clear filters")
    /// A row title in a card, such as an Inbox entry: 14/20 semibold.
    static let strongBody = TypeToken(name: "list strong body", face: .sfPro, size: 14, lineHeight: 20, weight: 600, tracking: 0, sample: "Refactored the append path")
    /// A history line: 13/20.
    static let history = TypeToken(name: "list history", face: .sfPro, size: 13, lineHeight: 20, weight: 400, tracking: 0, sample: "Mentored on the ledger model")
    static let historyStrong = TypeToken(name: "list history strong", face: .sfPro, size: 13, lineHeight: 20, weight: 600, tracking: 0, sample: "You logged it")
    /// The origin badge and the After wrap-up mark: 11/16 semibold, untracked, as the prototype's `.origin` and `.late`.
    static let badge = TypeToken(name: "list badge", face: .sfPro, size: 11, lineHeight: 16, weight: 600, tracking: 0, sample: "collected")
    /// The empty state's line: rounded 22/28 heavy, the claim role.
    static let emptyTitle = CadenceType.claim
}

enum ListMetrics {
    static let row = CadenceSize.taskRow
    static let rowInset = CadenceSpace.s12
    /// A work-colour dot in a list: 9 points, as the prototype's `.fam`.
    static let familyDot: CGFloat = 9
    /// The larger dot that leads an Inbox card.
    static let familyDotLarge = CadenceSpace.s12
    /// A day's run of rows has the inner-control corner.
    static let groupRadius = CadenceRadius.control
    static let searchWidth: CGFloat = 280
    /// The detail panel beside the list, as the prototype's `.logg.with`.
    static let detailWidth: CGFloat = 300
    static let iconButton = CadenceSize.controlToolbar
    static let focusRing = CadenceSpace.s2
    /// The history's rule on its left.
    static let historyRule = CadenceSpace.s2
    /// A hovered row takes this much ink over the card; an open row this much brand, as the prototype's `.entry`.
    static let hoverTint = 0.04
    static let selectedTint = 0.12
    /// The After wrap-up mark: brand over the card, as the prototype's `.late`.
    static let lateTint = 0.18
    /// A quiet control under the pointer takes this much ink over its track, as the prototype's `.choice:hover`.
    static let quietHoverTint = 0.12
    static let pressScale: CGFloat = 0.97
    static let disabled = 0.45
}

/// Label and control on the first line, title on the second, at the same place on every section (section 6.4).
struct SectionHead<Control: View>: View {
    let label: String
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CadenceSpace.s12) {
                Text(label)
                    .cadenceType(CadenceType.label)
                    .foregroundStyle(CadenceColor.ink3.color)
                Spacer(minLength: 0)
                control()
            }
            .frame(height: CadenceSize.controlSecondary)
            Text(title)
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: CadenceSize.controlSecondary, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A work colour as a dot. Never alone: a word sits beside it, and Differentiate Without Colour adds the kind's name.
/// Some work colours fall below 3:1 on the light grounds, so in the light theme, and in both under Increase Contrast,
/// the dot gains an `ink` hairline that carries the mark (section 6.7, decision of 2026-11-03).
struct FamilyDot: View {
    let family: Family
    var size = ListMetrics.familyDot
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Circle()
            .fill(CadenceColor.family(family).color)
            .overlay(Circle().strokeBorder(Self.edged(scheme, contrast) ? CadenceColor.ink.color : .clear, lineWidth: CadenceStroke.hair))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func edged(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Bool {
        scheme == .light || contrast == .increased
    }
}

/// The origin as a quiet badge (OriginBadge, section 6.5): the ledger's word, never a celebratory pill.
struct OriginBadge: View {
    let origin: Origin

    var body: some View {
        Text(EntryWords.origin(origin))
            .cadenceType(ListType.badge)
            .foregroundStyle(CadenceColor.ink3.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, CadenceSpace.s6)
            .help(EntryWords.originMeaning(origin))
    }
}

/// A title as a field on `track`, in the title's own type, as the prototype's `.inl`: Return saves, Esc cancels. In
/// discreet mode its words are hidden like any title (section 6.7).
struct InlineTitleField: View {
    let text: String
    let type: TypeToken
    let discreet: Bool
    let set: (String) -> Void
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let binding = Binding(get: { text }, set: set)
        Group {
            if discreet {
                SecureField("", text: binding)
            } else {
                TextField("", text: binding)
            }
        }
        .textFieldStyle(.plain)
        .cadenceType(type)
        .foregroundStyle(CadenceColor.ink.color)
        .focused($focused)
        .focusEffectDisabled()
        .onSubmit(save)
        .onExitCommand(perform: cancel)
        .padding(.horizontal, CadenceSpace.s8)
        .padding(.vertical, CadenceSpace.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous).fill(CadenceColor.track.color))
        .overlay(
            RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
                .strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: ListMetrics.focusRing))
        .accessibilityLabel(TitleEdit.editTitle)
        .accessibilityHint("Return saves a new version. Escape keeps the title as it was.")
        .onAppear { focused = true }
    }
}

/// Why an edit was refused, under the field: `warn`, so it reads as a stop and not as the entry's line.
struct EditProblem: View {
    let text: String

    var body: some View {
        Text(text)
            .cadenceType(CadenceType.comparison)
            .foregroundStyle(CadenceColor.warn.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A work colour as a menu item's image. Menus draw SwiftUI shapes as templates, so the dot is drawn in AppKit, not as
/// a template, and follows the appearance when drawn, edged as `FamilyDot` is.
enum FamilyDotImage {
    static func image(_ family: Family) -> NSImage {
        let size = NSSize(width: ListMetrics.familyDot, height: ListMetrics.familyDot)
        let image = NSImage(size: size, flipped: false) { rect in
            CadenceColor.family(family).nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let appearance = NSAppearance.currentDrawing()
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let more = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) != nil
            if FamilyDot.edged(dark ? .dark : .light, more ? .increased : .standard) {
                let edge = NSBezierPath(ovalIn: rect.insetBy(dx: CadenceStroke.hair / 2, dy: CadenceStroke.hair / 2))
                edge.lineWidth = CadenceStroke.hair
                CadenceColor.ink.nsColor.setStroke()
                edge.stroke()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = EntryWords.family(family)
        return image
    }
}

/// A ticket key in the figure face on `track`, 20 points high.
struct LogTicketChip: View {
    let key: String

    var body: some View {
        Text(key)
            .cadenceType(CadenceType.figure)
            .foregroundStyle(CadenceColor.ink2.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, CadenceSpace.s6)
            .frame(height: CadenceSize.ticket)
            .background(RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous).fill(CadenceColor.track.color))
    }
}

/// "After wrap-up": an entry added after its day was sealed. Ink on a brand tint, so it reads at 4.5:1.
struct AfterWrapUpMark: View {
    var body: some View {
        Text(LogContent.afterWrapUp)
            .cadenceType(ListType.badge)
            .foregroundStyle(CadenceColor.ink.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, CadenceSpace.s6)
            .background(Capsule().fill(CadenceColor.brand.color.opacity(ListMetrics.lateTint)))
    }
}

/// The window's capsule buttons (section 6.1): primary in `ink` on `canvas`, quiet and choice on `track`.
struct WindowButtonStyle: ButtonStyle {
    enum Kind {
        /// `ink` capsule, 32 high: Accept.
        case primarySmall
        /// `track` capsule, 40 high: Clear filters.
        case quiet
        /// `track` capsule, 32 high: Dismiss, Accept all.
        case choice
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        WindowButton(configuration: configuration, kind: kind)
    }
}

private struct WindowButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: WindowButtonStyle.Kind
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .cadenceType(type)
            .foregroundStyle(kind == .primarySmall ? CadenceColor.canvas.color : CadenceColor.ink.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, kind == .quiet ? CadenceSpace.s16 : CadenceSpace.s12)
            .frame(height: kind == .quiet ? CadenceSize.controlPrimary : CadenceSize.controlSecondary)
            .background(Capsule().fill(fill))
            .background(Capsule().fill(base))
            .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: ListMetrics.focusRing))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? ListMetrics.pressScale : 1)
            .opacity(enabled ? 1 : ListMetrics.disabled)
            .onHover { hover = $0 }
            .cadenceAnimation(CadenceMotion.press.animation, value: configuration.isPressed)
            .cadenceAnimation(CadenceMotion.press.animation, value: hover)
    }

    private var type: TypeToken {
        switch kind {
        case .primarySmall: ListType.smallAction
        case .quiet: ListType.action
        case .choice: ListType.chip
        }
    }

    private var base: Color {
        kind == .primarySmall ? CadenceColor.ink.color : CadenceColor.track.color
    }

    /// Ink over the track under the pointer, as `color-mix(ink 12%, track)`. The primary lifts by scale alone.
    private var fill: Color {
        guard kind != .primarySmall, hover || configuration.isPressed else { return Color.clear }
        return CadenceColor.ink.color.opacity(ListMetrics.quietHoverTint)
    }
}

/// A filter chip, 28 high: `card` at rest, `ink` when on.
struct FilterChipStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        FilterChip(configuration: configuration, isOn: isOn)
    }
}

private struct FilterChip: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    @State private var hover = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .cadenceType(ListType.chip)
            .foregroundStyle(isOn ? CadenceColor.canvas.color : hover ? CadenceColor.ink.color : CadenceColor.ink2.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, CadenceSpace.s12)
            .frame(height: CadenceSize.controlToolbar)
            .background(Capsule().fill(isOn ? CadenceColor.ink.color : CadenceColor.card.color))
            .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: ListMetrics.focusRing))
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .cadenceAnimation(CadenceMotion.press.animation, value: isOn)
    }
}

/// A square icon button, 28 points, such as Close details.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration)
    }
}

private struct IconButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
        configuration.label
            .foregroundStyle(hover || configuration.isPressed ? CadenceColor.ink.color : CadenceColor.ink2.color)
            .frame(width: ListMetrics.iconButton, height: ListMetrics.iconButton)
            .background(shape.fill(hover || configuration.isPressed ? CadenceColor.track.color : Color.clear))
            .overlay(shape.strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: ListMetrics.focusRing))
            .contentShape(shape)
            .onHover { hover = $0 }
    }
}

/// An empty list: what it is, a line on what to do, and at most one action (sections 4.6 and 6.6).
struct ListEmptyState<Art: View, Action: View>: View {
    let title: String
    let line: String
    @ViewBuilder let art: () -> Art
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(spacing: CadenceSpace.s8) {
            art()
            Text(title)
                .cadenceType(ListType.emptyTitle)
                .foregroundStyle(CadenceColor.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .cadenceType(CadenceType.body)
                .foregroundStyle(CadenceColor.ink2.color)
                .multilineTextAlignment(.center)
            action()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CadenceSpace.s40)
        .padding(.horizontal, CadenceSpace.s12)
        .accessibilityElement(children: .contain)
    }
}
