// What Settings and first run ask the rest of the app to do. Each is a closure or a small protocol value, so the
// app wires the real login item, notifications, approvals, jobs and backups, and tests and snapshots pass fakes.
import AppKit
import CadenceCore
import Foundation

/// Whether Cadence opens at login (SMAppService.mainApp). The status is nil when macOS cannot say.
public struct LoginItemControl {
    public var status: @MainActor () -> Bool?
    /// Turns it on or off and returns the status afterwards.
    public var set: @MainActor (Bool) async -> Bool?

    public init(status: @escaping @MainActor () -> Bool?, set: @escaping @MainActor (Bool) async -> Bool?) {
        self.status = status
        self.set = set
    }

    public static var unavailable: LoginItemControl { LoginItemControl(status: { nil }, set: { _ in nil }) }
}

/// What notification permission macOS has given Cadence.
public enum NotificationPermission: Sendable, Equatable {
    case notAsked, allowed, denied, unknown
}

public struct NotificationControl {
    public var status: @MainActor () async -> NotificationPermission
    /// Asks macOS once; afterwards only System Settings can change the answer.
    public var request: @MainActor () async -> NotificationPermission

    public init(
        status: @escaping @MainActor () async -> NotificationPermission,
        request: @escaping @MainActor () async -> NotificationPermission
    ) {
        self.status = status
        self.request = request
    }

    public static var unavailable: NotificationControl { NotificationControl(status: { .unknown }, request: { .unknown }) }
}

/// Core's approval by digest (`CollectorRunner.approve` and `isApproved`, docs/SPEC.md section 10.2).
public protocol CollectorApproving {
    @MainActor func isApproved(_ plan: CollectorPlan) -> Bool
    @MainActor func approve(_ plan: CollectorPlan) throws(CadenceError)
}

/// FileVault as `FileVaultCheck` read it. Unknown is not off.
public enum FileVaultState: Sendable, Equatable {
    case on, off, unknown

    /// From `cadence doctor`'s check result: only its two definite answers count.
    public init(_ result: AgentChecks.Result) {
        if result.level == .ok, result.detail.hasPrefix("FileVault is on") {
            self = .on
        } else if result.detail.hasPrefix("FileVault is off") {
            self = .off
        } else {
            self = .unknown
        }
    }
}

public struct SettingsActions {
    public var loginItem: LoginItemControl
    public var notifications: NotificationControl
    /// Nil until the app wires Core's approval; Approve then explains it cannot record one.
    public var approval: (any CollectorApproving)?
    /// Drops a run job in `jobs/` for the agent. True when the request was written.
    public var runNow: @MainActor (String) async -> Bool
    /// Today's backup now, if there is none yet.
    public var backUpNow: @MainActor () async -> Result<BackupOutcome, StoreFailure>
    /// Discreet mode on or off, as `⌃⌥D` does.
    public var setDiscreet: @MainActor (Bool) -> Void
    /// Registers the shortcuts and returns the ones another app holds.
    public var applyHotkeys: @MainActor (HotkeyBindings) -> [HotkeyClash]
    /// Called after the preferences were saved, so the app can update Tempo, sounds and reminders.
    public var preferencesChanged: @MainActor (AppPreferences) -> Void
    /// Called after config.json was saved and read back.
    public var configChanged: @MainActor (Config) -> Void
    public var showInFinder: @MainActor (URL) -> Void
    public var copy: @MainActor (String) -> Void

    public init(
        loginItem: LoginItemControl = .unavailable, notifications: NotificationControl = .unavailable,
        approval: (any CollectorApproving)? = nil, runNow: @escaping @MainActor (String) async -> Bool = { _ in false },
        backUpNow: @escaping @MainActor () async -> Result<BackupOutcome, StoreFailure> = {
            .failure(StoreFailure(kind: .other, summary: String(localized: "Back up now is not available"), detail: "not wired"))
        },
        setDiscreet: @escaping @MainActor (Bool) -> Void = { _ in },
        applyHotkeys: @escaping @MainActor (HotkeyBindings) -> [HotkeyClash] = { _ in [] },
        preferencesChanged: @escaping @MainActor (AppPreferences) -> Void = { _ in },
        configChanged: @escaping @MainActor (Config) -> Void = { _ in },
        showInFinder: @escaping @MainActor (URL) -> Void = SettingsActions.revealInFinder,
        copy: @escaping @MainActor (String) -> Void = SettingsActions.copyToPasteboard
    ) {
        self.loginItem = loginItem
        self.notifications = notifications
        self.approval = approval
        self.runNow = runNow
        self.backUpNow = backUpNow
        self.setDiscreet = setDiscreet
        self.applyHotkeys = applyHotkeys
        self.preferencesChanged = preferencesChanged
        self.configChanged = configChanged
        self.showInFinder = showInFinder
        self.copy = copy
    }

    @MainActor public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor public static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
