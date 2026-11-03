// Settings' state (docs/SPEC.md section 4.6). Config edits are validated, saved through ConfigStore with mode 0600
// and read back, so the pane always shows what the file holds. Preferences go to UserDefaults. The ledger is never
// touched here: config.json and approvals are files, and every ledger write stays with AppWriter.
import CadenceCore
import Foundation
import Observation

@MainActor @Observable
public final class SettingsModel {
    public var pane: SettingsPane = .general
    public private(set) var snapshot: SettingsSnapshot
    /// The last thing an action said, such as a saved backup or a refused edit. Cleared by the next action.
    public private(set) var notice: Notice?
    /// The source whose command is being shown for approval or in detail.
    public var presentedSource: SourceRow?
    /// Whether the guided restore is showing.
    public var showsRestore = false

    public struct Notice: Sendable, Equatable {
        public var text: String
        public var good: Bool
        public var pane: SettingsPane
    }

    @ObservationIgnored public let roots: FileRoots
    @ObservationIgnored let preferenceStore: PreferenceStore
    @ObservationIgnored let actions: SettingsActions
    @ObservationIgnored let fallbackZone: String
    @ObservationIgnored let userHome: URL
    @ObservationIgnored let today: () -> LocalDate

    public init(
        roots: FileRoots, selfExecutable: String, actions: SettingsActions, defaults: UserDefaults = .standard,
        entitlements: EntitlementReport = EntitlementReader.current(), version: String = SettingsModel.bundleVersion(),
        fileVault: FileVaultState = .unknown, housekeeping: HousekeepingStatus = HousekeepingStatus(), discreet: Bool = false,
        clashes: [HotkeyClash] = [], locale: Locale = .current, fallbackZone: String = TimeZone.current.identifier,
        userHome: URL = SettingsFormat.userHome, today: @escaping () -> LocalDate
    ) {
        self.roots = roots
        self.preferenceStore = PreferenceStore(defaults: defaults)
        self.actions = actions
        self.fallbackZone = fallbackZone
        self.userHome = userHome
        self.today = today
        snapshot = SettingsSnapshot(
            config: Config.defaults(timezone: fallbackZone), preferences: preferenceStore.load(), discreet: discreet,
            openAtLogin: actions.loginItem.status(), housekeeping: housekeeping, clashes: clashes,
            selfExecutable: selfExecutable, fileVault: fileVault, entitlements: entitlements, version: version,
            store: StoreFacts.read(roots, userHome: userHome), today: today(), locale: locale)
        reload()
    }

    public static func bundleVersion(_ bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return String(localized: "Cadence \(short ?? "-")")
    }

    public func rows(_ pane: SettingsPane) -> [SettingsRow] { SettingsRows.rows(pane, snapshot) }

    /// Reads config.json, the preferences, the store's files and the approvals again.
    public func reload() {
        do throws(CadenceError) {
            let (config, check) = try ConfigStore.load(from: roots.config, fallbackZone: fallbackZone)
            snapshot.config = config
            snapshot.configProblem = check.exists && !check.safe ? check.problem : nil
        } catch {
            snapshot.configProblem = String(localized: "config.json could not be read: \(error.message)")
        }
        snapshot.preferences = preferenceStore.load()
        snapshot.openAtLogin = actions.loginItem.status()
        snapshot.store = StoreFacts.read(roots, userHome: userHome)
        snapshot.today = today()
        refreshApprovals()
    }

    // MARK: What the app tells Settings

    public func update(housekeeping: HousekeepingStatus) { snapshot.housekeeping = housekeeping }
    public func update(fileVault: FileVaultState) { snapshot.fileVault = fileVault }
    public func update(discreet: Bool) { snapshot.discreet = discreet }
    public func update(clashes: [HotkeyClash]) { snapshot.clashes = clashes }

    // MARK: Switches

    public func set(_ toggle: SettingsToggle, _ on: Bool) async {
        notice = nil
        switch toggle {
        case .openAtLogin:
            snapshot.openAtLogin = await actions.loginItem.set(on)
        case .showTempo: editPreferences { $0.showTempo = on }
        case .showStreak: editPreferences { $0.showStreak = on }
        case .agentSound: editPreferences { $0.agentSound = on }
        case .remindOnWeekends: editPreferences { $0.remindOnWeekends = on }
        case .hideTitlesOnLockScreen: editPreferences { $0.hideTitlesOnLockScreen = on }
        case .discreet:
            snapshot.discreet = on
            actions.setDiscreet(on)
        case .notificationTitles: editConfig(.reminders) { $0.privacy.notificationTitles = on }
        case .afterWrapUp: break
        }
    }

    public func setSound(_ level: Config.Sounds) { editConfig(.general) { $0.sounds = level } }

    /// Adds or removes one wrap-up time, "HH:MM".
    public func toggleWrap(_ time: String) {
        editConfig(.reminders) { config in
            if config.reminders.contains(where: { $0.kind == .wrap && $0.at == time }) {
                config.reminders.removeAll { $0.kind == .wrap && $0.at == time }
            } else {
                config.reminders.append(Config.Reminder(kind: .wrap, at: time))
            }
        }
    }

    /// From the "Add time" picker.
    public func addWrap(hour: Int, minute: Int) {
        let time = String(format: "%02d:%02d", hour, minute)
        guard !snapshot.config.reminders.contains(where: { $0.kind == .wrap && $0.at == time }) else { return }
        toggleWrap(time)
    }

    /// A new shortcut from the recorder. It is kept even when it clashes, so the message names it.
    public func setHotkey(_ binding: HotkeyBinding) {
        notice = nil
        var keys = snapshot.preferences.hotkeys
        switch binding.action {
        case .capture: keys.capture = binding
        case .quickNote: keys.quickNote = binding
        case .discreet: keys.discreet = binding
        }
        if let other = keys.all.first(where: { $0.action != binding.action && $0.keyCode == binding.keyCode && $0.modifiers == binding.modifiers }) {
            notice = Notice(text: String(localized: "\(binding.display) is already used by \(Self.name(of: other.action))."), good: false, pane: .capture)
            return
        }
        editPreferences { $0.hotkeys = keys }
        snapshot.clashes = actions.applyHotkeys(keys)
    }

    static func name(of action: HotkeyBinding.Action) -> String {
        switch action {
        case .capture: String(localized: "Capture")
        case .quickNote: String(localized: "Quick note")
        case .discreet: String(localized: "Discreet mode")
        }
    }

    // MARK: Sources

    public func perform(_ action: SourceAction, on row: SourceRow) async {
        notice = nil
        switch action {
        case .approve, .details:
            presentedSource = row
        case .runNow:
            let written = await actions.runNow(row.name)
            notice = Notice(
                text: written ? String(localized: "\(row.title) will run in a moment. Everything else keeps working.") : String(localized: "\(row.title) could not be asked to run. Try again."),
                good: written, pane: .sources)
        }
    }

    /// Records approval of exactly the plan that was shown.
    public func approve(_ row: SourceRow) {
        presentedSource = nil
        guard let plan = row.plan else { return }
        guard let approval = actions.approval else {
            notice = Notice(text: String(localized: "Cadence could not record the approval. Run cadence collect approve \(row.name) in Terminal."), good: false, pane: .sources)
            return
        }
        do throws(CadenceError) {
            try approval.approve(plan)
            refreshApprovals()
            notice = Notice(text: String(localized: "\(row.title) approved. It runs on the agent's next pass."), good: true, pane: .sources)
        } catch {
            notice = Notice(text: String(localized: "\(row.title) was not approved: \(error.message)"), good: false, pane: .sources)
        }
    }

    private func refreshApprovals() {
        guard let approval = actions.approval else {
            snapshot.approved = []
            return
        }
        var approved: Set<String> = []
        for collector in snapshot.config.collectors {
            if let plan = try? CollectorRunner.plan(for: collector, selfExecutable: snapshot.selfExecutable), approval.isApproved(plan) {
                approved.insert(collector.name)
            }
        }
        snapshot.approved = approved
    }

    // MARK: Data

    public func press(_ button: SettingsButton) async {
        notice = nil
        switch button {
        case .backUpNow:
            switch await actions.backUpNow() {
            case .success(let outcome):
                let text = outcome.created ? String(localized: "Backed up. Today's copy is saved.") : String(localized: "Today's backup was already there. Nothing was replaced.")
                notice = Notice(text: text, good: true, pane: .data)
            case .failure(let failure):
                notice = Notice(text: String(localized: "\(failure.summary). Your log is unchanged."), good: false, pane: .data)
            }
            snapshot.store = StoreFacts.read(roots, userHome: userHome)
        case .showInFinder:
            actions.showInFinder(roots.home)
        case .restore:
            showsRestore = true
        }
    }

    public func showBackup(_ day: LocalDate) {
        actions.showInFinder(roots.backups.appendingPathComponent(Backups.fileName(for: day)))
    }

    public func copy(_ text: String) { actions.copy(text) }

    // MARK: Saving

    private func editPreferences(_ change: (inout AppPreferences) -> Void) {
        var preferences = snapshot.preferences
        change(&preferences)
        preferenceStore.save(preferences)
        snapshot.preferences = preferenceStore.load()
        actions.preferencesChanged(snapshot.preferences)
    }

    /// Validates the edited config by reading its own JSON back, saves it with mode 0600 and reloads. An edit the
    /// config rules refuse is not saved, and the notice says why.
    private func editConfig(_ pane: SettingsPane, _ change: (inout Config) -> Void) {
        notice = nil
        var config = snapshot.config
        change(&config)
        do throws(CadenceError) {
            let bytes: [UInt8]
            do {
                bytes = try CanonicalJSON.bytes(config.json)
            } catch {
                throw .validation("config cannot be written as canonical JSON")
            }
            _ = try Config.parse(bytes: bytes, fallbackZone: fallbackZone)
            try ConfigStore.save(config, to: roots.config)
        } catch {
            notice = Notice(text: String(localized: "That change was not saved: \(error.message)"), good: false, pane: pane)
            return
        }
        reload()
        actions.configChanged(snapshot.config)
    }
}
