// Settings' and first run's roles, built from the tokens of docs/SPEC.md section 6 and sized as the approved
// prototype's `.setnav`, `.kv`, `.sw`, `.src`, `.choice`, `.chip`, `.status`, `.code`, `.btn` and `.ob` rules
// (coach.css). Sizes come only from the type scale of section 6.3.
import AppKit
import SwiftUI

enum SettingsType {
    /// A pane in the side list.
    static let nav = TypeToken(name: "settings nav", face: .sfPro, size: 13, lineHeight: 20, weight: 600, tracking: 0, sample: "General")
    /// A row's name.
    static let rowTitle = TypeToken(name: "settings row", face: .sfPro, size: 14, lineHeight: 20, weight: 500, tracking: 0, sample: "Show Tempo")
    /// A row's value, right-aligned.
    static let rowValue = TypeToken(name: "settings value", face: .sfPro, size: 14, lineHeight: 20, weight: 600, tracking: 0, sample: "FileVault is on")
    /// A source's name.
    static let sourceTitle = TypeToken(name: "settings source", face: .sfPro, size: 14, lineHeight: 20, weight: 600, tracking: 0, sample: "GitHub")
    /// A row's second line, hints and a source's state.
    static let detail = CadenceType.comparison
    static let state = TypeToken(name: "settings state", face: .sfPro, size: 12, lineHeight: 16, weight: 600, tracking: 0, sample: "Needs approval")
    /// Choice buttons and status strips.
    static let choice = TypeToken(name: "settings choice", face: .sfPro, size: 13, lineHeight: 20, weight: 600, tracking: 0, sample: "Back up now")
    static let status = choice
    static let chip = TypeToken(name: "settings chip", face: .sfPro, size: 12, lineHeight: 16, weight: 600, tracking: 0, sample: "17:30")
    /// Commands and patterns: Geist Mono is for tickets, times and hashes, and a command is read the same way.
    static let mono = CadenceType.figure
    static let code = TypeToken(name: "settings code", face: .geistMono, size: 13, lineHeight: 20, weight: 500, tracking: 0, sample: "cadence setup claude-code --apply")
    /// "Cadence 0.1" in About.
    static let product = TypeToken(name: "settings product", face: .sfPro, size: 18, lineHeight: 24, weight: 700, tracking: 0, sample: "Cadence 0.1")
    /// Capsule buttons.
    static let button = TypeToken(name: "settings button", face: .sfPro, size: 14, lineHeight: 20, weight: 700, tracking: 0, sample: "Continue")
    /// A sheet's title.
    static let sheetTitle = CadenceType.claim
    /// First run's headline: 34/40 heavy rounded, as the prototype's `.obmain h2`.
    static let headline = TypeToken(name: "first run headline", face: .sfRounded, size: 34, lineHeight: 40, weight: 900, tracking: -0.03, sample: "Your log lives here.")
}

enum SettingsMetrics {
    /// The side list, as the prototype's `.setwrap` column.
    static let navWidth: CGFloat = CadenceSpace.s40 * 4
    static let navGap = CadenceSpace.s2
    static let navItem = CadenceSize.controlSecondary
    /// The body never grows past the prototype's `.setwrap` width less the list.
    static let bodyMaxWidth: CGFloat = CadenceSpace.s48 * 15
    static let row = CadenceSize.settingsRow
    static let rowPadding = CadenceSpace.s8
    static let headRow = CadenceSize.controlSecondary
    static let choice = CadenceSize.controlSecondary
    static let chip = CadenceSize.chip
    static let key = CadenceSize.ticket
    static let button = CadenceSize.controlPrimary
    static let focusRing = CadenceSpace.s2
    static let tempo: CGFloat = CadenceSpace.s32 * 2 + CadenceSpace.s6
    /// Status strips tint their ground with their own colour at this strength, as the prototype's 13% mix.
    static let tint = 0.13
    /// Chip and choice hover darken the track with ink at this strength.
    static let hover = 0.12
    static let pressScale: CGFloat = 0.97
    /// The switch, as the prototype's `.sw i`: 38 by 22 with a knob inset by 2.
    static let switchWidth: CGFloat = CadenceSpace.s40 - CadenceSpace.s2
    static let switchHeight: CGFloat = CadenceSpace.s24 - CadenceSpace.s2
    static let switchInset = CadenceSpace.s2
    static let disabled = 0.45
}

enum FirstRunMetrics {
    /// The art and text columns share the width 5 to 7, as `.ob`.
    static let artShare: CGFloat = 5
    static let mainShare: CGFloat = 7
    static let minHeight: CGFloat = CadenceSpace.s40 * 14
    static let padding = CadenceSpace.s32
    /// Above the step bars, inside the padding, so the longest step still sits near the middle of the card.
    static let top = CadenceSpace.s48
    static let tempo: CGFloat = CadenceSpace.s40 * 4 + CadenceSpace.s32 - CadenceSpace.s2
    static let stepBar = CadenceSpace.s4
    static let stepGap = CadenceSpace.s4
}

/// A status strip: the finding, an icon so it never relies on colour, and a tint of `good` or `warn`.
struct StatusStrip: View {
    let text: String
    let good: Bool

    var body: some View {
        let tone = good ? CadenceColor.good : CadenceColor.warn
        HStack(alignment: .firstTextBaseline, spacing: CadenceSpace.s6) {
            Image(systemName: good ? "checkmark.circle" : "exclamationmark.triangle")
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .cadenceType(SettingsType.status)
        .foregroundStyle(tone.color)
        .padding(.vertical, CadenceSpace.s8)
        .padding(.horizontal, CadenceSpace.s12)
        .background(RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous).fill(tone.color.opacity(SettingsMetrics.tint)))
        .accessibilityElement(children: .combine)
    }
}

/// A command shown exactly, in a quiet block that can be selected and copied.
struct CodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .cadenceType(SettingsType.code)
            .foregroundStyle(CadenceColor.ink.color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, CadenceSpace.s8)
            .padding(.horizontal, CadenceSpace.s12)
            .background(RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous).fill(CadenceColor.track.color))
    }
}

/// Quiet capsule buttons on `track`: Back up now, Approve, Run now, Copy.
struct ChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ChoiceButton(configuration: configuration) }
}

private struct ChoiceButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .cadenceType(SettingsType.choice)
            .foregroundStyle(CadenceColor.ink.color)
            .lineLimit(1)
            .padding(.horizontal, CadenceSpace.s12)
            .frame(height: SettingsMetrics.choice)
            .background(
                Capsule().fill(CadenceColor.track.color)
                    .overlay(Capsule().fill(CadenceColor.ink.color.opacity(hover || configuration.isPressed ? SettingsMetrics.hover : 0))))
            .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : .clear, lineWidth: SettingsMetrics.focusRing))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : SettingsMetrics.disabled)
            .scaleEffect(configuration.isPressed && !reduceMotion ? SettingsMetrics.pressScale : 1)
            .onHover { hover = $0 }
            .cadenceAnimation(CadenceMotion.press.animation, value: hover)
            .cadenceAnimation(CadenceMotion.press.animation, value: configuration.isPressed)
    }
}

/// Capsule buttons at 40 points: primary in `ink` on `canvas`, quiet on `track` (section 6.1).
struct SettingsCapsuleButtonStyle: ButtonStyle {
    var quiet = false

    func makeBody(configuration: Configuration) -> some View { CapsuleButton(configuration: configuration, quiet: quiet) }
}

private struct CapsuleButton: View {
    let configuration: ButtonStyleConfiguration
    let quiet: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .cadenceType(SettingsType.button)
            .foregroundStyle(quiet ? CadenceColor.ink.color : CadenceColor.canvas.color)
            .lineLimit(1)
            .padding(.horizontal, CadenceSpace.s16)
            .frame(height: SettingsMetrics.button)
            .background(
                Capsule().fill(quiet ? CadenceColor.track.color : CadenceColor.ink.color)
                    .overlay(Capsule().fill(CadenceColor.ink.color.opacity(quiet && (hover || configuration.isPressed) ? SettingsMetrics.hover : 0))))
            .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : .clear, lineWidth: SettingsMetrics.focusRing))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : SettingsMetrics.disabled)
            .scaleEffect(configuration.isPressed && !reduceMotion ? SettingsMetrics.pressScale : 1)
            .onHover { hover = $0 }
            .cadenceAnimation(CadenceMotion.press.animation, value: configuration.isPressed)
    }
}

/// A quiet text button, as the prototype's `.link`: Back, Done.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelTextButtonStyle(type: SettingsType.choice, height: SettingsMetrics.choice).makeBody(configuration: configuration)
    }
}

/// The switch: `track` when off, `good` when on, a white knob that slides. The knob's side says the state as well as
/// the colour, and the whole switch is a button, so it takes keyboard focus and reads as a switch to VoiceOver.
struct CadenceSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { CadenceSwitch(configuration: configuration) }
}

private struct CadenceSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    var body: some View {
        let on = configuration.isOn
        let knob = SettingsMetrics.switchHeight - SettingsMetrics.switchInset * 2
        Button {
            configuration.isOn.toggle()
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        } label: {
            Capsule()
                .fill(on ? CadenceColor.good.color : CadenceColor.track.color)
                .overlay(Capsule().strokeBorder(CadenceColor.line.color, lineWidth: CadenceStroke.hair))
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(Color.white)
                        .frame(width: knob, height: knob)
                        .padding(SettingsMetrics.switchInset)
                }
                .frame(width: SettingsMetrics.switchWidth, height: SettingsMetrics.switchHeight)
                .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : .clear, lineWidth: SettingsMetrics.focusRing))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : SettingsMetrics.disabled)
        .cadenceAnimation(CadenceMotion.press.animation, value: on)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}
