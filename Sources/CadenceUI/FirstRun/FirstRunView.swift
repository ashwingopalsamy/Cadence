// First run on the lilac world (docs/SPEC.md sections 4.6 and 6.2): Tempo's pose for the step on the left, the
// words on the right, as the approved prototype's `firstRun()`. The card keeps one height, so stepping through never
// moves it. Below the compact width Tempo steps aside and the text has the whole card.
import CadenceCore
import SwiftUI

public struct FirstRunView: View {
    @Bindable var model: FirstRunModel
    /// Tempo shows only when it is on and discreet mode is off.
    let showsTempo: Bool
    @State private var width: CGFloat = 0

    public init(model: FirstRunModel, showsTempo: Bool) {
        self.model = model
        self.showsTempo = showsTempo
    }

    private var compact: Bool { width > 0 && width < CadenceSize.compactWidth }

    public var body: some View {
        HStack(spacing: 0) {
            if !compact {
                ZStack {
                    CadenceWorld.lilac.bg.color
                    if showsTempo {
                        TempoView(TempoSpec(pose: model.step.pose), size: FirstRunMetrics.tempo)
                            .id(model.step)
                    }
                }
                .frame(width: width * FirstRunMetrics.artShare / (FirstRunMetrics.artShare + FirstRunMetrics.mainShare))
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)
            }
            FirstRunStepView(model: model)
                .padding(compact ? CadenceSpace.s20 : FirstRunMetrics.padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(minHeight: FirstRunMetrics.minHeight)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        .background(CadenceColor.card.color)
        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.card, style: .continuous))
        .task { await model.refreshPermissions() }
    }
}

struct FirstRunStepView: View {
    let model: FirstRunModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepBars(current: model.step)
                .accessibilityElement()
                .accessibilityLabel(model.progress)
            Text(headline)
                .cadenceType(SettingsType.headline)
                .foregroundStyle(CadenceColor.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, CadenceSpace.s16)
                .padding(.bottom, CadenceSpace.s8)
            content
            navigation.padding(.top, CadenceSpace.s20)
            Spacer(minLength: 0)
        }
        // One top edge for every step, so the bars and the headline never move while stepping through.
        .padding(.top, FirstRunMetrics.top)
        .cadenceAnimation(CadenceMotion.open.animation, value: model.step)
    }

    private var headline: String {
        switch model.step {
        case .welcome: String(localized: "Hello. I keep time for your work.")
        case .yourData: String(localized: "Your log lives here.")
        case .github: String(localized: "Bring in your GitHub work?")
        case .claudeCode: String(localized: "Log your Claude Code sessions?")
        case .history: String(localized: "Start with some history?")
        case .permissions: String(localized: "Two small permissions.")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome:
            Paragraph(
                String(localized: "I log what you plan and what you do, then help you tell the story at review time. Your log stays on this Mac. This app makes no network calls, and any source you connect runs only a command you approve.")
            )
        case .yourData:
            Paragraph(String(localized: "A private folder on this Mac, with daily backups. You can read it with the command-line tool whenever you like."))
            CodeBlock(text: model.folder)
            switch model.fileVault {
            case .on: StatusStrip(text: String(localized: "FileVault is on, so your log is encrypted at rest."), good: true).padding(.top, CadenceSpace.s8)
            case .off:
                StatusStrip(
                    text: String(localized: "FileVault is off, so your log is not encrypted at rest. Turn it on in System Settings, Privacy & Security."),
                    good: false
                ).padding(.top, CadenceSpace.s8)
            case .unknown: SettingsHint(String(localized: "Cadence could not read the FileVault state. Run cadence doctor in Terminal to check.")).padding(.top, CadenceSpace.s8)
            }
        case .github:
            github
        case .claudeCode:
            Paragraph(
                String(localized: "A small hook records when sessions start and end, and a skill lets Claude log what it did. Nothing from your code or prompts is read.")
            )
            CodeBlock(text: FirstRunModel.claudeCodeCommand)
            SettingsHint(String(localized: "Cadence cannot change Claude Code's settings from inside its sandbox, so run this once in Terminal. It saves a backup of your settings first."))
                .padding(.top, CadenceSpace.s8)
            if model.copied.contains(.claudeCode) {
                StatusStrip(text: String(localized: "Copied. Paste it in Terminal, then carry on here."), good: true).padding(.top, CadenceSpace.s8)
            } else {
                actionRow(String(localized: "Copy the command")) { model.copyCommand(for: .claudeCode) }
            }
        case .history:
            Paragraph(String(localized: "Bring in October so your usual range starts sooner. Backfilled entries are always labelled as backfilled."))
            if let command = model.importCommand {
                CodeBlock(text: command)
                SettingsHint(String(localized: "Run it in Terminal with your own export file. The dry run writes nothing; run it again without --dry-run to import. It reads only that file and sends nothing."))
                    .padding(.top, CadenceSpace.s8)
                if model.copied.contains(.history) {
                    StatusStrip(text: String(localized: "Copied. Paste it in Terminal, then carry on here."), good: true).padding(.top, CadenceSpace.s8)
                } else {
                    actionRow(String(localized: "Copy the import command")) { model.copyCommand(for: .history) }
                }
            } else {
                SettingsHint(String(localized: "No map yet. Once one is in the maps folder, cadence import genai brings October in from Terminal."))
            }
        case .permissions:
            Paragraph(String(localized: "Both are optional, and you can change them in Settings."))
            RowFrame {
                RowLabel(title: String(localized: "Open Cadence at login"), detail: String(localized: "So your day is tracked without you thinking about it."))
                Spacer(minLength: CadenceSpace.s12)
                Toggle("Open Cadence at login", isOn: Binding(get: { model.openAtLogin ?? false }, set: { on in Task { await model.setOpenAtLogin(on) } }))
                    .toggleStyle(CadenceSwitchStyle())
                    .disabled(model.openAtLogin == nil)
            }
            RowFrame {
                RowLabel(title: String(localized: "Plan and wrap-up reminders"), detail: remindersDetail)
                Spacer(minLength: CadenceSpace.s12)
                Toggle("Plan and wrap-up reminders", isOn: Binding(get: { model.notifications == .allowed }, set: { on in Task { await model.setReminders(on) } }))
                    .toggleStyle(CadenceSwitchStyle())
                    .disabled(model.notifications == .allowed || model.notifications == .denied)
            }
        }
    }

    private var remindersDetail: String {
        model.notifications == .denied
            ? String(localized: "Notifications are off for Cadence. Turn them on in System Settings, Notifications.")
            : String(localized: "Counts only, never titles. macOS will ask you once.")
    }

    @ViewBuilder private var github: some View {
        if let offer = model.github {
            Paragraph(String(localized: "Merges and reviews can log themselves, if you approve this exact command."))
            CodeBlock(text: offer.command)
            SettingsHint(String(localized: "\(offer.schedule). Talks to \(offer.host). Reads your PRs and reviews, and sends nothing from your log."))
                .padding(.top, CadenceSpace.s8)
            if model.githubApproved {
                StatusStrip(text: String(localized: "Approved. GitHub syncs on the next run of the collector agent."), good: true).padding(.top, CadenceSpace.s8)
            } else {
                if let problem = model.githubProblem { StatusStrip(text: problem, good: false).padding(.top, CadenceSpace.s8) }
                actionRow(String(localized: "Approve this command")) { model.approveGitHub() }
            }
        } else {
            Paragraph(String(localized: "Merges and reviews can log themselves through gh, once a GitHub source is in config.json."))
            SettingsHint(
                model.githubProblem.map { String(localized: "The GitHub source in config.json cannot run: \($0)") }
                    ?? String(localized: "There is none yet. Add it whenever you like, and approve it in Settings, Sources."))
        }
    }

    /// The step's own action, as a primary button above the navigation.
    private func actionRow(_ title: String, _ action: @escaping () -> Void) -> some View {
        HStack {
            Button(title, action: action)
                .buttonStyle(SettingsCapsuleButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.top, CadenceSpace.s12)
    }

    /// Back on the left; Skip for now and the primary on the right. While a step's own action waits, it holds the
    /// primary place and the step offers only Skip for now.
    private var navigation: some View {
        let step = model.step
        let pending = stepActionPending
        return HStack(spacing: CadenceSpace.s8) {
            Button("Back") { model.back() }
                .buttonStyle(LinkButtonStyle())
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)
                .accessibilityHidden(step == .welcome)
            Spacer(minLength: 0)
            if step.isSkippable && pending {
                Button("Skip for now") { model.skip() }
                    .buttonStyle(SettingsCapsuleButtonStyle(quiet: true))
            } else {
                Button(primaryTitle) { step == .permissions ? model.finish() : model.next() }
                    .buttonStyle(SettingsCapsuleButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    /// The step has an action of its own that has not happened yet.
    private var stepActionPending: Bool {
        switch model.step {
        case .github: model.github != nil && !model.githubApproved
        case .claudeCode: !model.copied.contains(.claudeCode)
        case .history: model.importCommand != nil && !model.copied.contains(.history)
        default: false
        }
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: String(localized: "Get started")
        case .permissions: String(localized: "Finish")
        default: String(localized: "Continue")
        }
    }
}

/// The six bars: done and current in ink, the rest on track. Decorative; the step is read out as "Step 3 of 6".
struct StepBars: View {
    let current: FirstRunStep

    var body: some View {
        HStack(spacing: FirstRunMetrics.stepGap) {
            ForEach(FirstRunStep.allCases) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? CadenceColor.ink.color : CadenceColor.track.color)
                    .frame(height: FirstRunMetrics.stepBar)
            }
        }
    }
}

private struct Paragraph: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .cadenceType(CadenceType.body)
            .foregroundStyle(CadenceColor.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, CadenceSpace.s8)
    }
}

private struct SettingsHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .cadenceType(SettingsType.detail)
            .foregroundStyle(CadenceColor.ink3.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
