// The sheets Settings opens: a source's exact command for approval or detail (docs/SPEC.md section 10.2), and the
// guided restore, which never overwrites anything. Sheets are 540 wide with 24 points of padding (section 6.4);
// secondary actions sit left of the primary, `⌘↩` is the primary and `esc` closes.
import AppKit
import CadenceCore
import SwiftUI

struct SettingsSheetFrame<Content: View, Actions: View>: View {
    let title: String
    let sentence: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s12) {
            Text(title)
                .cadenceType(SettingsType.sheetTitle)
                .foregroundStyle(CadenceColor.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text(sentence)
                .cadenceType(CadenceType.body)
                .foregroundStyle(CadenceColor.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            content
            HStack(spacing: CadenceSpace.s8) {
                Spacer(minLength: 0)
                actions
            }
            .padding(.top, CadenceSpace.s8)
        }
        .padding(CadenceSpace.sheetPadding)
        .frame(width: CadenceSize.sheetWidth, alignment: .leading)
        .background(CadenceColor.card.color)
    }
}

/// Approve shows exactly what will run and asks; Details shows the same text and offers Run now.
struct SourceSheet: View {
    let row: SourceRow
    let model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsSheetFrame(title: heading, sentence: sentence) {
            if let text = row.approvalText {
                ScrollView { CodeBlock(text: text) }
                    .frame(maxHeight: CadenceSpace.s48 * 5)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .invalid(let why) = row.state {
                StatusStrip(text: String(localized: "This source cannot run: \(why)"), good: false)
            }
            Text(row.reads)
                .cadenceType(SettingsType.detail)
                .foregroundStyle(CadenceColor.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(SettingsCapsuleButtonStyle(quiet: true))
                .keyboardShortcut(.cancelAction)
            if row.action == .approve {
                Button("Approve this command") { model.approve(row) }
                    .buttonStyle(SettingsCapsuleButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
            } else if row.plan != nil, row.state != .off, row.state != .needsApproval {
                Button("Run now") {
                    dismiss()
                    Task { await model.perform(.runNow, on: row) }
                }
                .buttonStyle(SettingsCapsuleButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private var heading: String { row.action == .approve ? String(localized: "Approve \(row.title)?") : row.title }

    private var sentence: String {
        switch row.state {
        case .needsApproval:
            String(localized: "This is exactly what will run, every argument and every setting. It runs only after you approve, and asks again if it changes.")
        case .off:
            String(localized: "This source is off in config.json, so it does not run.")
        case .invalid:
            String(localized: "Fix this source in config.json, and it will ask for approval here.")
        case .ok(let text), .failing(let text):
            String(localized: "\(text). This is exactly what runs, as you approved it.")
        }
    }
}

/// Restore, guided. Core has no restore yet, so the flow never replaces the log: it shows the backups, where they
/// are, and what to run to check them.
struct RestoreSheet: View {
    let model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let backups = model.snapshot.store.backups
        SettingsSheetFrame(
            title: String(localized: "Restore from a backup"),
            sentence: String(localized: "Restoring never overwrites your log. Cadence cannot restore from inside the app yet, so your backups stay as they are.")
        ) {
            if backups.isEmpty {
                Text("There are no backups yet. The first one is made today.")
                    .cadenceType(CadenceType.body)
                    .foregroundStyle(CadenceColor.ink2.color)
            } else {
                VStack(spacing: 0) {
                    ForEach(backups.prefix(5), id: \.self) { day in
                        RowFrame {
                            Text(SettingsFormat.day(day, today: model.snapshot.today, locale: model.snapshot.locale))
                                .cadenceType(SettingsType.rowTitle)
                                .foregroundStyle(CadenceColor.ink.color)
                            Spacer(minLength: CadenceSpace.s12)
                            Button("Show in Finder") { model.showBackup(day) }
                                .buttonStyle(ChoiceButtonStyle())
                        }
                    }
                }
            }
            Text("To check a backup, run this in Terminal:")
                .cadenceType(CadenceType.body)
                .foregroundStyle(CadenceColor.ink2.color)
            CodeBlock(text: "cadence backup list --verify")
        } actions: {
            Button("Copy command") { model.copy("cadence backup list --verify") }
                .buttonStyle(SettingsCapsuleButtonStyle(quiet: true))
            Button("Done") { dismiss() }
                .buttonStyle(SettingsCapsuleButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
        }
        .onExitCommand { dismiss() }
    }
}

/// The shortcut key. Click it, then press the new shortcut; `esc` cancels. A shortcut needs ⌃, ⌥ or ⌘, so plain
/// typing can never be taken.
struct HotkeyRecorder: View {
    let binding: HotkeyBinding
    let title: String
    let onChange: (HotkeyBinding) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? String(localized: "Type a shortcut") : binding.display)
        }
        .buttonStyle(TimeChipStyle(on: !recording))
        .accessibilityLabel("\(title) shortcut")
        .accessibilityValue(recording ? String(localized: "Recording") : binding.display)
        .accessibilityHint("Press to record a new shortcut")
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // esc
                stop()
                return nil
            }
            guard let next = Self.binding(from: event, action: binding.action) else { return nil }
            stop()
            onChange(next)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func binding(from event: NSEvent, action: HotkeyBinding.Action) -> HotkeyBinding? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: HotkeyBinding.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        guard !modifiers.isDisjoint(with: [.control, .option, .command]),
            let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 })
        else { return nil }
        return HotkeyBinding(action: action, keyCode: UInt32(event.keyCode), key: key, modifiers: modifiers)
    }
}
