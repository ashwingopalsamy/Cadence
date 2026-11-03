// The parts every sheet shares (docs/SPEC.md sections 4.4, 4.5, 6.1 and 6.4): one width, glass with a solid fallback,
// the kicker, the title, the step bar, capsule buttons, key caps and the footer with the primary rightmost.
import AppKit
import CadenceCore
import SwiftUI

/// Geometry of a sheet. One width and one top edge, so stepping through a flow never moves it.
public enum SheetLayout {
    public static let width = CadenceSize.sheetWidth
    public static let padding = CadenceSpace.sheetPadding
    public static let radius = CadenceRadius.card
    /// The top edge sits this far under the top of the screen's visible frame, as in the design's sheet layer.
    public static let topInset = CadenceSpace.s48 + CadenceSpace.s24
    /// A pick row in the morning plan.
    public static let pickRow = CadenceSize.foundRow
    public static let tick = CadenceSpace.s20
    public static let tickStroke = CadenceSpace.s2
    public static let familyDot = CadenceSpace.s8
    public static let stepBar = CadenceSpace.s4
    /// A step not reached yet, as a share of ink.
    public static let stepOff = 0.25
    public static let tileHeight = CadenceSpace.s48
    /// The quiet fill behind the add field's button: ink at this share over the track.
    public static let addFill = 0.1
}

/// Type for sheet parts the spec's roles do not name, built from its scale (section 6.3).
public enum SheetType {
    public static let button = TypeToken(name: "button", face: .sfPro, size: 14, lineHeight: 20, weight: 700, tracking: 0, sample: "Start the day")
    public static let choice = TypeToken(name: "choice", face: .sfPro, size: 13, lineHeight: 20, weight: 600, tracking: 0, sample: "Move to tomorrow")
    public static let small = TypeToken(name: "small action", face: .sfPro, size: 12, lineHeight: 16, weight: 600, tracking: 0, sample: "Leave")
    public static let key = TypeToken(name: "key", face: .sfPro, size: 11, lineHeight: 16, weight: 600, tracking: 0, sample: "⌘↩")
    public static let row = TypeToken(name: "row", face: .sfPro, size: 14, lineHeight: 20, weight: 500, tracking: 0, sample: "Draft the replay ADR")
    public static let tileCount = TypeToken(name: "tile count", face: .sfRounded, size: 18, lineHeight: 24, weight: 800, tracking: 0, sample: "2")
    public static let sealLine = TypeToken(name: "seal line", face: .sfPro, size: 18, lineHeight: 24, weight: 500, tracking: 0, sample: "Rest well.")
}

/// How a sheet's ground is drawn. Glass on floating chrome; solid under Reduce Transparency, and in snapshots.
public enum SheetSurface: Sendable {
    case automatic
    case solid
}

extension EnvironmentValues {
    @Entry public var sheetSurface: SheetSurface = .automatic
}


/// The sheet's frame: fixed width, sheet padding, glass or its solid fallback.
struct SheetFrame<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.sheetSurface) private var surface
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SheetLayout.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(SheetLayout.padding)
            .frame(width: SheetLayout.width, alignment: .leading)
            .background {
                if reduceTransparency || surface == .solid {
                    shape.fill(CadenceColor.panel.opaque)
                }
            }
            .modifier(GlassUnlessSolid(solid: reduceTransparency || surface == .solid, shape: shape))
            .clipShape(shape)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isModal)
    }
}

private struct GlassUnlessSolid<S: Shape>: ViewModifier {
    let solid: Bool
    let shape: S

    func body(content: Content) -> some View {
        if solid {
            content
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

/// The small line above a title.
struct SheetKicker: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .cadenceType(CadenceType.label)
            .foregroundStyle(CadenceColor.ink3.color)
            .lineLimit(1)
    }
}

/// The sheet's one title.
struct SheetTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .cadenceType(CadenceType.section)
            .foregroundStyle(CadenceColor.ink.color)
            .padding(.top, CadenceSpace.s4)
            .padding(.bottom, CadenceSpace.s8)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One plain line under a title.
struct SheetLead: View {
    let text: String
    var color: ColorToken = CadenceColor.ink3

    init(_ text: String, color: ColorToken = CadenceColor.ink3) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .cadenceType(CadenceType.body)
            .foregroundStyle(color.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The step bar: one segment per question, filled up to the current one.
struct StepBar: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: CadenceSpace.s4) {
            ForEach(0..<max(count, 1), id: \.self) { index in
                Capsule()
                    .fill(CadenceColor.ink.color.opacity(index <= current ? 1 : SheetLayout.stepOff))
                    .frame(height: SheetLayout.stepBar)
            }
        }
        .padding(.bottom, CadenceSpace.s16)
        .accessibilityElement()
        .accessibilityLabel("Step \(min(current, count - 1) + 1) of \(count)")
    }
}

/// A key cap, as a hint beside an action.
struct KeyCap: View {
    let keys: String
    /// On a primary button the cap is a tint of the label colour, not a track.
    var inverted = false

    var body: some View {
        Text(keys)
            .cadenceType(SheetType.key)
            .padding(.horizontal, CadenceSpace.s6)
            .foregroundStyle(inverted ? CadenceColor.canvas.color : CadenceColor.ink2.color)
            .background(
                RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
                    .fill(inverted ? CadenceColor.canvas.color.opacity(SheetLayout.stepOff) : CadenceColor.track.color)
            )
            .accessibilityHidden(true)
    }
}

/// The capsule buttons of section 6.1: primary in ink on canvas, quiet on track, a choice on track, a link in ink-2.
struct SheetButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        /// The primary answer inside a row of choices: ink, at the choices' height (section 6.5, ChoiceRow).
        case primaryChoice
        case quiet
        case choice
        case link
        case small
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        SheetButtonBody(kind: kind, configuration: configuration)
    }
}

private struct SheetButtonBody: View {
    let kind: SheetButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    var body: some View {
        configuration.label
            .cadenceType(type)
            .lineLimit(1)
            .padding(.horizontal, horizontal)
            .frame(height: height)
            .foregroundStyle(foreground.color)
            .background(background)
            .overlay {
                if isFocused {
                    shape.stroke(CadenceColor.focus.color, lineWidth: SheetLayout.tickStroke)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : CadenceDisabled.opacity)
            .scaleEffect(configuration.isPressed && !reduceMotion ? CadenceDisabled.pressScale : 1)
            .animation(CadenceMotion.resolved(CadenceMotion.press.animation, reduceMotion: reduceMotion), value: configuration.isPressed)
            .onHover { hover = $0 }
    }

    private var shape: AnyShape {
        switch kind {
        case .link, .small: AnyShape(RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous))
        default: AnyShape(Capsule())
        }
    }

    private var type: TypeToken {
        switch kind {
        case .primary, .quiet: SheetType.button
        case .primaryChoice, .choice, .link: SheetType.choice
        case .small: SheetType.small
        }
    }

    private var height: CGFloat {
        switch kind {
        case .primary, .quiet: CadenceSize.controlPrimary
        case .primaryChoice, .choice, .link: CadenceSize.controlSecondary
        case .small: CadenceSize.chip
        }
    }

    private var horizontal: CGFloat {
        switch kind {
        case .primary, .quiet: CadenceSpace.s16
        case .primaryChoice, .choice: CadenceSpace.s12
        case .link, .small: CadenceSpace.s8
        }
    }

    private var foreground: ColorToken {
        switch kind {
        case .primary, .primaryChoice: CadenceColor.canvas
        case .quiet, .choice: CadenceColor.ink
        case .link, .small: hover ? CadenceColor.ink : CadenceColor.ink2
        }
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .primary, .primaryChoice:
            shape.fill(CadenceColor.ink.color)
        case .quiet, .choice:
            shape.fill(hover && isEnabled ? CadenceColor.ink.color.opacity(SheetLayout.addFill) : CadenceColor.track.color)
        case .link, .small:
            shape.fill(hover && isEnabled ? CadenceColor.track.color : Color.clear)
        }
    }
}

/// Disabled and pressed states (section 6.5).
enum CadenceDisabled {
    static let opacity = 0.4
    static let pressScale = 0.97
}

/// The footer: secondary actions on the left, then the primary rightmost.
struct SheetFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: CadenceSpace.s8) {
            leading
            Spacer(minLength: CadenceSpace.s8)
            trailing
        }
        .padding(.top, CadenceSpace.s16)
    }
}

/// What failed, in one line above the footer, while the answers stay on screen.
struct SheetIssue: View {
    let issue: StoreFailure?

    var body: some View {
        if let issue {
            Text("\(issue.summary). Your answers are kept.")
                .cadenceType(CadenceType.comparison)
                .foregroundStyle(CadenceColor.warn.color)
                .padding(.top, CadenceSpace.s12)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// A date as the kicker shows it, in the system locale ("Thursday 29 Oct").
enum SheetDate {
    static func kicker(_ date: LocalDate, locale: Locale = .current) -> String {
        format(date, template: "EEEEdMMM", locale: locale)
    }

    static func weekday(_ date: LocalDate, locale: Locale = .current) -> String {
        format(date, template: "EEEE", locale: locale)
    }

    private static func format(_ date: LocalDate, template: String, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(year: date.year, month: date.month, day: date.day, hour: 12)
        guard let instant = calendar.date(from: components) else { return date.description }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = .gmt
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: instant)
    }
}

/// How titles show in a sheet: through `AppState.title`, so discreet mode reads "Task 1" and hides ticket keys.
public struct SheetTitles {
    public let discreet: Bool
    private let render: @MainActor (String, Int, String) -> String

    /// Titles as the app shows them.
    @MainActor public init(app: AppState) {
        discreet = app.discreet
        render = { app.title($0, index: $1, word: $2) }
    }

    /// Titles as written, for specimens and tests.
    public init(discreet: Bool = false) {
        self.discreet = discreet
        render = { discreet ? "\($2) \($1 + 1)" : $0 }
    }

    @MainActor func callAsFunction(_ text: String, index: Int, word: String = String(localized: "Task")) -> String {
        render(text, index, word)
    }
}
