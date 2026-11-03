import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

@MainActor
@Suite struct SettingsTests {
    static let today = LocalDate(year: 2026, month: 10, day: 29)!
    static let helper = "/Users/you/Applications/Cadence.app/Contents/Helpers/cadence"
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    final class Approvals: CollectorApproving {
        var approved: Set<String>
        init(_ approved: Set<String> = []) { self.approved = approved }
        func isApproved(_ plan: CollectorPlan) -> Bool { approved.contains(plan.name) }
        func approve(_ plan: CollectorPlan) throws(CadenceError) { approved.insert(plan.name) }
    }

    static func config() -> Config {
        var config = Config.defaults(timezone: "Asia/Kolkata")
        config.reminders = [Config.Reminder(kind: .plan, after: "dayStart+2m"), Config.Reminder(kind: .wrap, at: "17:30"), Config.Reminder(kind: .wrap, at: "19:15")]
        config.collectors = [
            Config.Collector(name: "github", builtin: "github", env: ["GH_HOST": "git.example.com"], every: "30m"),
            Config.Collector(name: "oncall", command: ["/Users/you/bin/acme-oncall.sh"], every: "60m"),
            Config.Collector(name: "paused", enabled: false, command: ["/usr/bin/true"]),
            Config.Collector(name: "broken", command: ["relative/path"]),
            Config.Collector(name: "usage", command: ["/usr/bin/curl", "http://127.0.0.1:8080/usage"], at: ["17:10"]),
        ]
        return config
    }

    /// The config without the source config.json itself would refuse, so it can be written and read back.
    static func savable() -> Config {
        var config = config()
        config.collectors.removeAll { $0.name == "broken" }
        return config
    }

    static func snapshot(_ config: Config = config(), approved: Set<String> = ["github", "oncall"], fileVault: FileVaultState = .on) -> SettingsSnapshot {
        let now = Date(timeIntervalSince1970: 1_793_268_720)
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        let sources = [
            CollectorSource.make(
                collector: config.collectors[0], failuresInARow: 0, lastError: nil, lastGoodRun: now.addingTimeInterval(-60),
                producedItems: true, now: now, zone: zone),
            CollectorSource.make(
                collector: config.collectors[1], failuresInARow: 3, lastError: "exit 1", lastGoodRun: nil, producedItems: false,
                now: now, zone: zone),
        ]
        return SettingsSnapshot(
            config: config, housekeeping: HousekeepingStatus(sources: sources), selfExecutable: helper, approved: approved,
            fileVault: fileVault, entitlements: EntitlementReport(sandboxed: true, networkKeys: []), version: "Cadence 0.1",
            store: StoreFacts(
                folder: URL(fileURLWithPath: "/Users/you/Library/Application Support/Cadence"),
                display: "~/Library/Application Support/Cadence", bytes: 4_312_000, backups: [today, today.adding(days: -1)], maps: []),
            today: today, locale: Locale(identifier: "en_GB"))
    }

    static func value(_ rows: [SettingsRow], _ id: String) -> String? {
        for row in rows { if case .value(let rowID, _, _, let value, _) = row, rowID == id { return value } }
        return nil
    }

    static func toggle(_ rows: [SettingsRow], _ key: SettingsToggle) -> (isOn: Bool, enabled: Bool)? {
        for row in rows { if case .toggle(let k, _, _, let isOn, let enabled) = row, k == key { return (isOn, enabled) } }
        return nil
    }

    // MARK: Rows from a config

    @Test func everyPaneHasRows() {
        let s = Self.snapshot()
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Reminders", "Capture", "Sources", "Tickets", "Privacy", "Data", "About"])
        for pane in SettingsPane.allCases { #expect(!SettingsRows.rows(pane, s).isEmpty) }
    }

    @Test func generalRows() {
        var config = Self.config()
        config.sounds = .off
        let rows = SettingsRows.rows(.general, Self.snapshot(config))
        #expect(rows.contains(.sound(.off)))
        #expect(Self.toggle(rows, .openAtLogin)! == (false, false))  // macOS did not say
        #expect(Self.toggle(rows, .showTempo)!.isOn)
        #expect(Self.toggle(rows, .agentSound)! == (false, false))  // sound is off
        #expect(Self.value(rows, "menuBarIcon") == "Icon only")
    }

    @Test func remindersRows() {
        let rows = SettingsRows.rows(.reminders, Self.snapshot())
        #expect(rows.contains(.wrapTimes(selected: ["17:30", "19:15"], shown: ["16:00", "17:30", "18:00", "19:15"])))
        #expect(Self.value(rows, "plan") == "2 min after your day starts")
        #expect(Self.value(rows, "dayEnds") == "04:00")
        #expect(Self.toggle(rows, .notificationTitles)!.isOn == false)
    }

    @Test func captureRowsCarryTheClashMessage() {
        var s = Self.snapshot()
        s.clashes = [HotkeyClash(binding: HotkeyBindings.standard.capture, status: -9878)]
        let rows = SettingsRows.rows(.capture, s)
        #expect(rows.contains(.status(id: "clash.capture", text: "⌃⌥L is already used by another app. Pick another shortcut, or use the menu-bar icon.", good: false)))
        #expect(Self.toggle(rows, .afterWrapUp)! == (true, false))
        #expect(Self.value(rows, "defaultKind") == "Note")
    }

    @Test func sourceRowsShowTheExactCommandAndState() {
        let rows = SettingsRows.sourceRows(Self.snapshot())
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        #expect(SettingsRows.rows(.sources, Self.snapshot()).first == .hint("A source only runs after you approve its exact command."))
        let github = byName["github"]!
        #expect(github.command == "\(Self.helper) collector github --since {since} --until {until} --name github")
        #expect(github.state == .ok("Synced 15:41"))
        #expect(github.action == .details)
        #expect(github.reads == "Every 30 min. Reads your PRs and reviews through gh on git.example.com.")
        #expect(github.approvalText?.contains("GH_HOST=\"git.example.com\"") == true)
        #expect(byName["oncall"]!.state == .failing("Failed 3 times in a row"))
        #expect(byName["oncall"]!.action == .runNow)
        #expect(byName["usage"]!.state == .needsApproval)
        #expect(byName["usage"]!.action == .approve)
        #expect(byName["paused"]!.state == .off)
        if case .invalid = byName["broken"]!.state {} else { Issue.record("a relative command is invalid") }
    }

    @Test func unsafeConfigTurnsSourcesOff() {
        var s = Self.snapshot()
        s.configProblem = "config.json is mode 0644; run chmod 600 /x/config.json"
        #expect(SettingsRows.rows(.sources, s).contains(.status(id: "config", text: "Sources are off. config.json is mode 0644; run chmod 600 /x/config.json", good: false)))
    }

    @Test func ticketRowsReadTheClassifierRules() {
        var config = Self.config()
        config.tickets.selfInitiated = "^9+$"
        let rows = SettingsRows.rows(.tickets, Self.snapshot(config))
        #expect(Self.value(rows, "pattern") == TicketRules.defaultPattern)
        #expect(Self.value(rows, "selfInitiated") == "^9+$")
        // ACME-000000 is not self-started under this rule, so the example does not claim it.
        #expect(rows.contains(.hint("Example: ACME-482913 counts as assigned. A PR with no ticket counts as neither.")))
        #expect(!rows.contains { if case .value(_, _, _, let v, _) = $0 { v.hasPrefix("SELF") } else { false } })
    }

    @Test func privacyRowsShowFileVault() {
        #expect(Self.value(SettingsRows.rows(.privacy, Self.snapshot(fileVault: .on)), "fileVault") == "FileVault is on")
        #expect(Self.value(SettingsRows.rows(.privacy, Self.snapshot(fileVault: .off)), "fileVault") == "FileVault is off")
        #expect(Self.value(SettingsRows.rows(.privacy, Self.snapshot(fileVault: .unknown)), "fileVault") == "-")
        #expect(Self.toggle(SettingsRows.rows(.privacy, Self.snapshot()), .hideTitlesOnLockScreen)!.enabled == false)
    }

    @Test func dataAndAboutRows() {
        let data = SettingsRows.rows(.data, Self.snapshot())
        #expect(Self.value(data, "folder") == "~/Library/Application Support/Cadence")
        #expect(Self.value(data, "backup") == "Today. 14 daily and 8 weekly kept.")
        #expect(data.contains(.buttons([.backUpNow, .showInFinder, .restore])))
        let about = SettingsRows.rows(.about, Self.snapshot())
        #expect(Self.value(about, "network") == "None. Read live from its entitlements.")
        #expect(Self.value(about, "sourcesNetwork") == "gh to git.example.com, acme-oncall.sh")
        #expect(Self.value(about, "sandbox") == "On")
    }

    @Test func fileVaultStateFromTheDoctorCheck() {
        #expect(FileVaultState(AgentChecks.Result(name: "filevault", level: .ok, detail: "FileVault is on, so the work log is encrypted at rest")) == .on)
        #expect(FileVaultState(AgentChecks.Result(name: "filevault", level: .warn, detail: "FileVault is off, so the work log is not encrypted at rest")) == .off)
        #expect(FileVaultState(AgentChecks.Result(name: "filevault", level: .warn, detail: "unknown, fdesetup could not be run")) == .unknown)
    }

    // MARK: Saving

    static func folder() throws -> FileRoots {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return FileRoots(home: home)
    }

    static func defaults() -> UserDefaults {
        let name = "cadence.tests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func model(_ roots: FileRoots, defaults: UserDefaults, approvals: Approvals? = nil, changed: @escaping @MainActor (Config) -> Void = { _ in }) -> SettingsModel {
        SettingsModel(
            roots: roots, selfExecutable: helper, actions: SettingsActions(approval: approvals, configChanged: changed),
            defaults: defaults, entitlements: EntitlementReport(sandboxed: true, networkKeys: []), version: "Cadence 0.1",
            locale: Locale(identifier: "en_GB"), fallbackZone: "Asia/Kolkata", today: { today })
    }

    @Test func configEditsSaveWith0600AndReload() async throws {
        let roots = try Self.folder()
        defer { try? FileManager.default.removeItem(at: roots.home) }
        try ConfigStore.save(Self.savable(), to: roots.config)
        var heard: Config?
        let model = Self.model(roots, defaults: Self.defaults()) { heard = $0 }
        model.toggleWrap("16:00")
        model.toggleWrap("17:30")
        model.addWrap(hour: 18, minute: 5)
        model.setSound(.full)
        await model.set(.notificationTitles, true)

        let (saved, check) = try ConfigStore.load(from: roots.config, fallbackZone: "Asia/Kolkata")
        #expect(check.mode == 0o600 && check.safe)
        #expect(Set(saved.reminders.filter { $0.kind == .wrap }.compactMap(\.at)) == ["16:00", "19:15", "18:05"])
        #expect(saved.sounds == .full)
        #expect(saved.privacy.notificationTitles)
        #expect(saved.collectors == Self.savable().collectors)
        #expect(model.snapshot.config == saved)
        #expect(heard == saved)
    }

    @Test func preferencesRoundTrip() async throws {
        let roots = try Self.folder()
        defer { try? FileManager.default.removeItem(at: roots.home) }
        let defaults = Self.defaults()
        let model = Self.model(roots, defaults: defaults)
        #expect(model.snapshot.preferences == AppPreferences())
        await model.set(.showTempo, false)
        await model.set(.agentSound, true)
        await model.set(.remindOnWeekends, true)
        model.setHotkey(HotkeyBinding(action: .capture, keyCode: 40, key: "K", modifiers: [.control, .command]))
        let loaded = PreferenceStore(defaults: defaults).load()
        #expect(!loaded.showTempo && loaded.agentSound && loaded.remindOnWeekends)
        #expect(loaded.hotkeys.capture.display == "⌃⌘K")
        #expect(loaded.hotkeys.quickNote == HotkeyBindings.standard.quickNote)
        // A shortcut another action already holds is refused with a message.
        model.setHotkey(HotkeyBinding(action: .discreet, keyCode: 40, key: "K", modifiers: [.control, .command]))
        #expect(model.notice?.text == "⌃⌘K is already used by Capture.")
        #expect(PreferenceStore(defaults: defaults).load().hotkeys.discreet == HotkeyBindings.standard.discreet)
    }

    @Test func approveRecordsTheShownPlan() throws {
        let roots = try Self.folder()
        defer { try? FileManager.default.removeItem(at: roots.home) }
        try ConfigStore.save(Self.savable(), to: roots.config)
        let approvals = Approvals()
        let model = Self.model(roots, defaults: Self.defaults(), approvals: approvals)
        let usage = try #require(SettingsRows.sourceRows(model.snapshot).first { $0.name == "usage" })
        #expect(usage.action == .approve)
        model.approve(usage)
        #expect(approvals.approved == ["usage"])
        #expect(model.snapshot.approved.contains("usage"))
        #expect(SettingsRows.sourceRows(model.snapshot).first { $0.name == "usage" }!.action == .details)
    }

    // MARK: Entitlements

    @Test func theTestProcessHasNoNetworkKey() {
        let report = EntitlementReader.current()
        #expect(report.networkKeys.isEmpty)
    }

    @Test func theAppEntitlementsSayNone() throws {
        let report = try #require(EntitlementReader.file(at: Self.repo.appendingPathComponent("App/Cadence.entitlements")))
        #expect(report.sandboxed)
        #expect(report.networkBlocked)
        #expect(report.networkSummary == "None. Read live from its entitlements.")
    }

    @Test func aNetworkKeyIsNamed() {
        let report = EntitlementReport(plist: ["com.apple.security.app-sandbox": true, "com.apple.security.network.client": true])
        #expect(!report.networkBlocked)
        #expect(report.networkSummary == "Allowed by com.apple.security.network.client")
        #expect(EntitlementReport(plist: [:]).networkSummary == "Not blocked. This build runs outside the app sandbox.")
    }
}
