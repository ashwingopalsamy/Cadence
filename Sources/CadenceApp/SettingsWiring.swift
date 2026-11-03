// Settings and first run, wired to the services they control (docs/SPEC.md section 4.6, T3.16 and T4.12).
import AppKit
import CadenceCore
import CadenceUI

@MainActor
enum SettingsWiring {
    struct Services {
        let app: AppState
        let writer: AppWriter
        let location: StoreLocation
        let loginItems: LoginItemController
        let notifications: Notifications?
        let sounds: CadenceSoundPlayer
        let applyHotkeys: @MainActor @Sendable (HotkeyBindings) -> [HotkeyClash]
        let clashes: [HotkeyClash]
        let sections: WindowSections
    }

    /// The `cadence` helper inside the bundle, symlinks resolved: approval digests cover this exact path.
    static var selfExecutable: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cadence").resolvingSymlinksInPath().path
    }

    static func loginItem(_ items: LoginItemController) -> LoginItemControl {
        LoginItemControl(
            status: { items.report.app == .enabled },
            set: { on in items.setEnabled(on, for: .app) == .enabled })
    }

    static func notificationControl(_ notifications: Notifications?) -> NotificationControl {
        func permission(_ access: NotificationAccess) -> NotificationPermission {
            switch access {
            case .notDetermined: .notAsked
            case .allowed: .allowed
            case .denied: .denied
            }
        }
        guard let notifications else { return .unavailable }
        return NotificationControl(
            status: { permission(notifications.access) },
            request: { permission(await notifications.authorize()) })
    }

    /// "Run now" drops a run request in `jobs/`; the collector agent picks it up (section 10.2).
    static func runNow(_ name: String, roots: FileRoots) -> Bool {
        let body = Data("{\"job\":\"run\",\"name\":\"\(name)\"}".utf8)
        let file = roots.jobs.appendingPathComponent("run-\(name)-\(UUID().uuidString).json")
        return (try? body.write(to: file, options: .atomic)) != nil
    }

    static func make(_ s: Services) -> (settings: SettingsModel?, firstRun: FirstRunModel?) {
        guard case .found(let roots) = s.location else { return (nil, nil) }
        let preferences = PreferenceStore(defaults: .standard)
        // The sound level is the config's; it holds from launch, not only after an edit in Settings.
        if let config = try? ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0 {
            s.sounds.settings.level = config.sounds
        }
        s.app.signals.setupFinished = preferences.setupFinished
        let apply: @MainActor @Sendable (AppPreferences) -> Void = { prefs in
            s.app.tempoEnabled = prefs.showTempo
            s.sounds.settings.agentLogged = prefs.agentSound
            s.sections.showsStreak = prefs.showStreak
        }
        apply(preferences.load())
        let actions = SettingsActions(
            loginItem: loginItem(s.loginItems), notifications: notificationControl(s.notifications),
            approval: StoreApprovals(roots: roots, selfExecutable: selfExecutable),
            runNow: { name in runNow(name, roots: roots) },
            backUpNow: { await s.writer.runBackup() },
            setDiscreet: { on in
                s.app.discreet = on
                s.notifications?.discreet = on
            },
            applyHotkeys: s.applyHotkeys,
            preferencesChanged: apply,
            configChanged: { config in
                s.sounds.settings.level = config.sounds
                s.app.model.reload()
            })
        let settings = SettingsModel(
            roots: roots, selfExecutable: selfExecutable, actions: actions, discreet: s.app.discreet, clashes: s.clashes,
            today: { s.app.today })
        let firstRun = FirstRunModel(
            roots: roots, selfExecutable: selfExecutable,
            actions: FirstRunActions(
                loginItem: loginItem(s.loginItems), notifications: notificationControl(s.notifications),
                approval: StoreApprovals(roots: roots, selfExecutable: selfExecutable),
                finished: {
                    s.app.signals.setupFinished = true
                    s.app.model.reload()
                }))
        return (settings, firstRun)
    }
}

/// Approving a collector's exact plan from Settings and first run (section 10.2). Approval writes only
/// `state/approvals.json`; nothing runs here, so the journal is read-only and never starts a ledger.
@MainActor
final class StoreApprovals: CollectorApproving {
    private let roots: FileRoots
    private let selfExecutable: String

    init(roots: FileRoots, selfExecutable: String) {
        self.roots = roots
        self.selfExecutable = selfExecutable
    }

    func isApproved(_ plan: CollectorPlan) -> Bool {
        (try? runner().isApproved(plan)) ?? false
    }

    func approve(_ plan: CollectorPlan) throws(CadenceError) {
        try runner().approve(plan)
    }

    private func runner() throws(CadenceError) -> CollectorRunner {
        let clock = SystemClock()
        let config = try ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0
        let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
        let exists = FileManager.default.fileExists(atPath: roots.database.path)
        let store = try SQLiteStore(
            path: exists ? roots.database.path : ":memory:", clock: clock, ids: ids, projector: LedgerProjector(), readOnly: exists)
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids, actor: .app, writesGenesis: false)
        return CollectorRunner(
            roots: roots, journal: journal, runner: SystemProcessRunner(), selfExecutable: selfExecutable,
            environment: ProcessInfo.processInfo.environment)
    }
}
