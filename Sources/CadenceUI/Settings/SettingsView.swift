// Settings (docs/SPEC.md section 4.6): eight panes in a side list, each a matte card of 44-point rows. Every row is
// drawn from `SettingsRows`, so what VoiceOver reads and what tests check is what the pane shows.
import CadenceCore
import SwiftUI

public struct SettingsView: View {
    @Bindable var model: SettingsModel
    /// Tempo shows in About only when it is on and discreet mode is off.
    let showsTempo: Bool

    public init(model: SettingsModel, showsTempo: Bool) {
        self.model = model
        self.showsTempo = showsTempo
    }

    @State private var width: CGFloat = 0

    public var body: some View {
        Group {
            if width > 0, width < CadenceSize.compactWidth + SettingsMetrics.navWidth {
                // Compact: the panes become a row above the card, and text wraps instead of truncating.
                VStack(alignment: .leading, spacing: CadenceSpace.s12) {
                    ScrollView(.horizontal, showsIndicators: false) { SettingsNav(pane: $model.pane, vertical: false) }
                    pane
                }
            } else {
                HStack(alignment: .top, spacing: CadenceSpace.s16) {
                    SettingsNav(pane: $model.pane, vertical: true)
                        .frame(width: SettingsMetrics.navWidth)
                    pane
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        .sheet(item: $model.presentedSource) { row in
            SourceSheet(row: row, model: model)
        }
        .sheet(isPresented: $model.showsRestore) {
            RestoreSheet(model: model)
        }
    }

    private var pane: some View {
        SettingsPaneView(model: model, pane: model.pane, showsTempo: showsTempo)
            .frame(maxWidth: SettingsMetrics.bodyMaxWidth, alignment: .topLeading)
    }
}

/// The side list. Each pane is a button; the current one reads as the page for VoiceOver.
struct SettingsNav: View {
    @Binding var pane: SettingsPane
    let vertical: Bool

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: SettingsMetrics.navGap)) : AnyLayout(HStackLayout(spacing: SettingsMetrics.navGap))
        layout {
            ForEach(SettingsPane.allCases) { item in
                Button(item.title) { pane = item }
                    .buttonStyle(NavItemStyle(current: item == pane, fullWidth: vertical))
                    .accessibilityAddTraits(item == pane ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings panes")
    }
}

private struct NavItemStyle: ButtonStyle {
    let current: Bool
    let fullWidth: Bool

    func makeBody(configuration: Configuration) -> some View {
        NavItem(configuration: configuration, current: current, fullWidth: fullWidth)
    }
}

private struct NavItem: View {
    let configuration: ButtonStyleConfiguration
    let current: Bool
    let fullWidth: Bool
    @State private var hover = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
        configuration.label
            .cadenceType(SettingsType.nav)
            .foregroundStyle(current || hover ? CadenceColor.ink.color : CadenceColor.ink2.color)
            .lineLimit(1)
            .padding(.horizontal, CadenceSpace.s12)
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
            .frame(height: SettingsMetrics.navItem)
            .background(shape.fill(current ? CadenceColor.card.color : hover ? CadenceColor.line.color : .clear))
            .overlay(shape.strokeBorder(focused ? CadenceColor.focus.color : .clear, lineWidth: SettingsMetrics.focusRing))
            .contentShape(shape)
            .onHover { hover = $0 }
            .cadenceAnimation(CadenceMotion.press.animation, value: hover)
    }
}

/// One pane: the section head ("Settings", then the pane's name) and its card of rows.
public struct SettingsPaneView: View {
    let model: SettingsModel
    let pane: SettingsPane
    let showsTempo: Bool

    public init(model: SettingsModel, pane: SettingsPane, showsTempo: Bool) {
        self.model = model
        self.pane = pane
        self.showsTempo = showsTempo
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .cadenceType(CadenceType.label)
                .foregroundStyle(CadenceColor.ink3.color)
                .frame(height: SettingsMetrics.headRow, alignment: .leading)
                .accessibilityHidden(true)
            Text(pane.title)
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
                .lineLimit(1)
                .frame(height: SettingsMetrics.headRow, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, CadenceSpace.s12)
            VStack(alignment: .leading, spacing: 0) {
                if let notice = model.notice, notice.pane == pane {
                    StatusStrip(text: notice.text, good: notice.good)
                        .padding(.vertical, CadenceSpace.s8)
                }
                ForEach(model.rows(pane)) { row in
                    SettingsRowView(row: row, model: model, showsTempo: showsTempo)
                }
            }
            .padding(.horizontal, CadenceSpace.s16)
            .padding(.top, CadenceSpace.s8)
            .padding(.bottom, CadenceSpace.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cadenceCard()
        }
    }
}

struct SettingsRowView: View {
    let row: SettingsRow
    let model: SettingsModel
    let showsTempo: Bool

    var body: some View {
        switch row {
        case .toggle(let key, let title, let detail, let isOn, let enabled):
            RowFrame {
                RowLabel(title: title, detail: detail)
                Spacer(minLength: CadenceSpace.s12)
                Toggle(title, isOn: Binding(get: { isOn }, set: { on in Task { await model.set(key, on) } }))
                    .toggleStyle(CadenceSwitchStyle())
                    .disabled(!enabled)
                    .accessibilityHint(detail ?? "")
            }
        case .value(_, let title, let detail, let value, let mono):
            RowFrame {
                RowLabel(title: title, detail: detail)
                Spacer(minLength: CadenceSpace.s12)
                if mono {
                    Text(value)
                        .cadenceType(SettingsType.mono)
                        .foregroundStyle(CadenceColor.ink2.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, CadenceSpace.s6)
                        .frame(height: SettingsMetrics.key)
                        .background(RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous).fill(CadenceColor.track.color))
                        .textSelection(.enabled)
                } else {
                    Text(value)
                        .cadenceType(SettingsType.rowValue)
                        .foregroundStyle(CadenceColor.ink2.color)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
        case .sound(let level):
            RowFrame {
                RowLabel(title: String(localized: "Sound"), detail: nil)
                Spacer(minLength: CadenceSpace.s12)
                Picker("Sound", selection: Binding(get: { level }, set: { model.setSound($0) })) {
                    Text("Off").tag(Config.Sounds.off)
                    Text("Subtle").tag(Config.Sounds.subtle)
                    Text("Full").tag(Config.Sounds.full)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        case .wrapTimes(let selected, let shown):
            RowFrame {
                RowLabel(title: String(localized: "Wrap-up reminders"), detail: nil)
                Spacer(minLength: CadenceSpace.s12)
                WrapChips(selected: selected, shown: shown, model: model)
            }
        case .hotkey(let binding, let title):
            RowFrame {
                RowLabel(title: title, detail: nil)
                Spacer(minLength: CadenceSpace.s12)
                HotkeyRecorder(binding: binding, title: title) { model.setHotkey($0) }
            }
        case .status(_, let text, let good):
            StatusStrip(text: text, good: good).padding(.vertical, CadenceSpace.s8)
        case .hint(let text):
            Text(text)
                .cadenceType(SettingsType.detail)
                .foregroundStyle(CadenceColor.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, CadenceSpace.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .source(let source):
            SourceRowView(row: source, model: model)
        case .buttons(let buttons):
            HStack(spacing: CadenceSpace.s8) {
                ForEach(buttons, id: \.self) { button in
                    Button(Self.title(button)) { Task { await model.press(button) } }
                        .buttonStyle(ChoiceButtonStyle())
                }
            }
            .padding(.top, CadenceSpace.s12)
            .padding(.bottom, CadenceSpace.s4)
        case .aboutHeader(let version):
            HStack(spacing: CadenceSpace.s16) {
                if showsTempo {
                    TempoView(TempoSpec(pose: .wrench), size: SettingsMetrics.tempo)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(version)
                        .cadenceType(SettingsType.product)
                        .foregroundStyle(CadenceColor.ink.color)
                    Text("Local-only work log")
                        .cadenceType(SettingsType.detail)
                        .foregroundStyle(CadenceColor.ink3.color)
                }
                .accessibilityElement(children: .combine)
            }
            .padding(.vertical, CadenceSpace.s8)
            .padding(.bottom, CadenceSpace.s4)
        }
    }

    static func title(_ button: SettingsButton) -> String {
        switch button {
        case .backUpNow: String(localized: "Back up now")
        case .showInFinder: String(localized: "Show in Finder")
        case .restore: String(localized: "Restore from a backup")
        }
    }
}

/// A 44-point row with a hairline under it. It grows only for a second line of detail.
struct RowFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.vertical, SettingsMetrics.rowPadding)
            .frame(minHeight: SettingsMetrics.row)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CadenceColor.line.color).frame(height: CadenceStroke.hair)
            }
    }
}

struct RowLabel: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .cadenceType(SettingsType.rowTitle)
                .foregroundStyle(CadenceColor.ink.color)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .cadenceType(SettingsType.detail)
                    .foregroundStyle(CadenceColor.ink3.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .layoutPriority(1)
    }
}

/// Wrap-up times as one-tap chips, then "Add time". A chosen chip carries a check, so the state is not colour alone.
struct WrapChips: View {
    let selected: [String]
    let shown: [String]
    let model: SettingsModel
    @State private var adding = false
    @State private var picked = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        HStack(spacing: CadenceSpace.s6) {
            ForEach(shown, id: \.self) { time in
                let on = selected.contains(time)
                Button {
                    model.toggleWrap(time)
                } label: {
                    HStack(spacing: CadenceSpace.s4) {
                        if on { Image(systemName: "checkmark").accessibilityHidden(true) }
                        Text(Self.display(time, locale: model.snapshot.locale))
                    }
                }
                .buttonStyle(TimeChipStyle(on: on))
                .accessibilityLabel(Self.display(time, locale: model.snapshot.locale))
                .accessibilityValue(on ? String(localized: "On") : String(localized: "Off"))
            }
            Button {
                adding = true
            } label: {
                HStack(spacing: CadenceSpace.s4) {
                    Image(systemName: "plus").accessibilityHidden(true)
                    Text("Add time")
                }
            }
            .buttonStyle(TimeChipStyle(on: false))
            .popover(isPresented: $adding) {
                VStack(alignment: .leading, spacing: CadenceSpace.s12) {
                    DatePicker("Wrap-up time", selection: $picked, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                    HStack {
                        Spacer()
                        Button("Add") {
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
                            model.addWrap(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
                            adding = false
                        }
                        .buttonStyle(ChoiceButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(CadenceSpace.s16)
            }
        }
    }

    static func display(_ time: String, locale: Locale) -> String {
        guard let (h, m) = SettingsFormat.parseClock(time) else { return time }
        return SettingsFormat.clock(hour: h, minute: m, locale: locale)
    }
}

/// A 24-point pill. Chosen: `track` with ink text and a check. Not chosen: an outline in `line`, ink-2 text.
struct TimeChipStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View { TimeChip(configuration: configuration, on: on) }
}

private struct TimeChip: View {
    let configuration: ButtonStyleConfiguration
    let on: Bool
    @State private var hover = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .cadenceType(SettingsType.chip)
            .foregroundStyle(on || hover ? CadenceColor.ink.color : CadenceColor.ink2.color)
            .lineLimit(1)
            .padding(.horizontal, CadenceSpace.s8)
            .frame(height: SettingsMetrics.chip)
            .background(
                Capsule().fill(on ? CadenceColor.track.color : .clear)
                    .overlay(Capsule().fill(CadenceColor.ink.color.opacity(hover || configuration.isPressed ? SettingsMetrics.hover / 2 : 0))))
            .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : on ? .clear : CadenceColor.line.color, lineWidth: focused ? SettingsMetrics.focusRing : CadenceStroke.hair))
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .cadenceAnimation(CadenceMotion.press.animation, value: hover)
    }
}

/// One source: its name, the exact command, what it reads and when, its state, and its one action.
struct SourceRowView: View {
    let row: SourceRow
    let model: SettingsModel

    var body: some View {
        RowFrame {
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .cadenceType(SettingsType.sourceTitle)
                    .foregroundStyle(CadenceColor.ink.color)
                    .lineLimit(1)
                Text(row.command.isEmpty ? "-" : row.command)
                    .cadenceType(SettingsType.mono)
                    .foregroundStyle(CadenceColor.ink3.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Text(row.reads)
                    .cadenceType(SettingsType.detail)
                    .foregroundStyle(CadenceColor.ink3.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: CadenceSpace.s12)
            HStack(spacing: CadenceSpace.s8) {
                HStack(spacing: CadenceSpace.s4) {
                    Image(systemName: icon).accessibilityHidden(true)
                    Text(row.stateText)
                }
                .cadenceType(SettingsType.state)
                .foregroundStyle(tone.color)
                .lineLimit(1)
                .fixedSize()
                Button(Self.title(row.action)) { Task { await model.perform(row.action, on: row) } }
                    .buttonStyle(ChoiceButtonStyle())
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.title), \(row.stateText)")
    }

    private var icon: String {
        switch row.state {
        case .ok: "checkmark.circle"
        case .needsApproval: "hand.raised"
        case .failing, .invalid: "exclamationmark.triangle"
        case .off: "pause.circle"
        }
    }

    private var tone: ColorToken {
        switch row.state {
        case .ok: CadenceColor.good
        case .needsApproval, .off: CadenceColor.ink2
        case .failing, .invalid: CadenceColor.warn
        }
    }

    static func title(_ action: SourceAction) -> String {
        switch action {
        case .approve: String(localized: "Approve")
        case .runNow: String(localized: "Run now")
        case .details: String(localized: "Details")
        }
    }
}
