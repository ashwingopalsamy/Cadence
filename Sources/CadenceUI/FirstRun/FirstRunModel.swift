// First run (docs/SPEC.md section 4.6): six steps on the lilac world, useful without any optional step. GitHub,
// Claude Code and History can be skipped. Each step says what it reads and what it sends: nothing from your log.
// Finish records that setup is done in UserDefaults, which `AppSignals.setupFinished` reads.
import CadenceCore
import Foundation
import Observation

public enum FirstRunStep: Int, CaseIterable, Sendable, Identifiable {
    case welcome, yourData, github, claudeCode, history, permissions

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .welcome: String(localized: "Welcome")
        case .yourData: String(localized: "Your data")
        case .github: String(localized: "GitHub")
        case .claudeCode: String(localized: "Claude Code")
        case .history: String(localized: "History")
        case .permissions: String(localized: "Permissions")
        }
    }

    /// Tempo's pose for the step, as the prototype's `OB_POSES`.
    public var pose: TempoPose.Name {
        switch self {
        case .welcome: .welcome
        case .yourData: .lock
        case .github: .plug
        case .claudeCode: .laptop
        case .history: .carry
        case .permissions: .raise
        }
    }

    /// The steps that offer "Skip for now".
    public var isSkippable: Bool { self == .github || self == .claudeCode || self == .history }
}

public struct FirstRunActions {
    public var loginItem: LoginItemControl
    public var notifications: NotificationControl
    /// Core's approval by digest. Nil until the app wires it; the GitHub step then points to Settings.
    public var approval: (any CollectorApproving)?
    public var copy: @MainActor (String) -> Void
    /// Called once, after the flag is saved, so the app can set `AppSignals.setupFinished` and close first run.
    public var finished: @MainActor () -> Void

    public init(
        loginItem: LoginItemControl = .unavailable, notifications: NotificationControl = .unavailable,
        approval: (any CollectorApproving)? = nil, copy: @escaping @MainActor (String) -> Void = SettingsActions.copyToPasteboard,
        finished: @escaping @MainActor () -> Void = {}
    ) {
        self.loginItem = loginItem
        self.notifications = notifications
        self.approval = approval
        self.copy = copy
        self.finished = finished
    }
}

@MainActor @Observable
public final class FirstRunModel {
    public static let claudeCodeCommand = "cadence setup claude-code --apply"

    /// The GitHub collector in config.json, as its exact plan.
    public struct GitHubOffer: Sendable, Equatable {
        public var plan: CollectorPlan
        /// The argv on one line, then each environment setting on its own line.
        public var command: String
        public var host: String
        public var schedule: String
    }

    public private(set) var step: FirstRunStep
    public private(set) var skipped: [FirstRunStep] = []
    public private(set) var finished = false
    public private(set) var github: GitHubOffer?
    /// Why the GitHub collector in config.json cannot be offered, when it cannot.
    public private(set) var githubProblem: String?
    public private(set) var githubApproved = false
    /// Commands copied, by step.
    public private(set) var copied: Set<FirstRunStep> = []
    public private(set) var openAtLogin: Bool?
    public private(set) var notifications: NotificationPermission = .unknown
    public var fileVault: FileVaultState
    public let folder: String
    /// The first map in `maps/`, which makes the October import possible.
    public let map: String?

    @ObservationIgnored let actions: FirstRunActions
    @ObservationIgnored let preferences: PreferenceStore

    public init(
        roots: FileRoots, selfExecutable: String, actions: FirstRunActions, defaults: UserDefaults = .standard,
        fileVault: FileVaultState = .unknown, fallbackZone: String = TimeZone.current.identifier,
        userHome: URL = SettingsFormat.userHome, startAt step: FirstRunStep = .welcome
    ) {
        self.step = step
        self.actions = actions
        self.preferences = PreferenceStore(defaults: defaults)
        self.fileVault = fileVault
        let facts = StoreFacts.read(roots, userHome: userHome)
        folder = facts.display
        map = facts.maps.first { $0.hasPrefix("october") } ?? facts.maps.first
        openAtLogin = actions.loginItem.status()
        // A missing or unreadable config offers no GitHub step; first run never writes config.json.
        let config = (try? ConfigStore.load(from: roots.config, fallbackZone: fallbackZone).0) ?? Config.defaults(timezone: fallbackZone)
        if let collector = config.collectors.first(where: { $0.builtin == "github" && $0.enabled }) {
            do throws(CadenceError) {
                let plan = try CollectorRunner.plan(for: collector, selfExecutable: selfExecutable)
                let env = plan.env.keys.sorted().map { "\($0)=\(plan.env[$0] ?? "")" }
                github = GitHubOffer(
                    plan: plan, command: ([([plan.executable] + plan.arguments).joined(separator: " ")] + env).joined(separator: "\n"),
                    host: collector.env["GH_HOST"] ?? "github.com", schedule: SettingsRows.schedule(collector))
                githubApproved = actions.approval?.isApproved(plan) ?? false
            } catch {
                githubProblem = error.message
            }
        }
    }

    public var steps: [FirstRunStep] { FirstRunStep.allCases }

    /// "Step 3 of 6", for VoiceOver.
    public var progress: String { String(localized: "Step \(step.rawValue + 1) of \(FirstRunStep.allCases.count)") }

    /// The October import, with the map that was found.
    public var importCommand: String? {
        map.map { "cadence import genai ~/Downloads/october-usage.csv --map maps/\($0) --dry-run" }
    }

    public func next() {
        guard let following = FirstRunStep(rawValue: step.rawValue + 1) else { return finish() }
        step = following
    }

    public func back() {
        guard let previous = FirstRunStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Leaves an optional step without doing it. Required steps cannot be skipped.
    public func skip() {
        guard step.isSkippable else { return }
        if !skipped.contains(step) { skipped.append(step) }
        next()
    }

    public func approveGitHub() {
        guard let github else { return }
        guard let approval = actions.approval else {
            githubProblem = String(localized: "Cadence could not record the approval here. Approve it in Settings, Sources.")
            return
        }
        do throws(CadenceError) {
            try approval.approve(github.plan)
            githubApproved = approval.isApproved(github.plan)
            githubProblem = nil
        } catch {
            githubProblem = String(localized: "It was not approved: \(error.message)")
        }
    }

    public func copyCommand(for step: FirstRunStep) {
        let text: String? =
            switch step {
            case .claudeCode: Self.claudeCodeCommand
            case .history: importCommand
            default: nil
            }
        guard let text else { return }
        actions.copy(text)
        copied.insert(step)
    }

    public func setOpenAtLogin(_ on: Bool) async {
        openAtLogin = await actions.loginItem.set(on)
    }

    /// Reminders need notifications, which macOS asks about once.
    public func setReminders(_ on: Bool) async {
        guard on else { return }
        notifications = await actions.notifications.request()
    }

    public func refreshPermissions() async {
        openAtLogin = actions.loginItem.status()
        notifications = await actions.notifications.status()
    }

    /// Marks setup finished. Safe to call twice.
    public func finish() {
        guard !finished else { return }
        var saved = preferences.load()
        saved.setupFinished = true
        preferences.save(saved)
        finished = true
        actions.finished()
    }
}
