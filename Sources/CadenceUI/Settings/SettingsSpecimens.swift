// Settings in all eight panes, from an ACME config written to a throwaway folder, a fixed day and the entitlements file
// the app is signed with. Shared by `make token-sheet` and the snapshot suite. Nothing here reads the real store.
import CadenceCore
import Foundation

@MainActor
public enum SettingsSpecimens {
    static let today = LocalDate(year: 2026, month: 10, day: 29)!
    public static let helper = "/Users/you/Applications/Cadence.app/Contents/Helpers/cadence"

    public final class Approvals: CollectorApproving {
        var approved: Set<String>
        public init(_ approved: Set<String>) { self.approved = approved }
        public func isApproved(_ plan: CollectorPlan) -> Bool { approved.contains(plan.name) }
        public func approve(_ plan: CollectorPlan) throws(CadenceError) { approved.insert(plan.name) }
    }

    /// One model per pane, in pane order, over one fixture under `home`. The Data pane shows `home` as the Mac's home
    /// folder, so the path it prints does not depend on where `home` is.
    public static func models(home: URL, entitlements: URL, defaultsSuite: String = "cadence.token-sheet.settings") -> [SettingsModel] {
        let roots = fixture(home: home)
        return SettingsPane.allCases.map { pane in
            let model = model(roots: roots, home: home, entitlements: entitlements, defaultsSuite: defaultsSuite)
            model.pane = pane
            return model
        }
    }

    static func model(roots: FileRoots, home: URL, entitlements file: URL, defaultsSuite: String) -> SettingsModel {
        let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
        defaults.removePersistentDomain(forName: defaultsSuite)
        let actions = SettingsActions(
            loginItem: LoginItemControl(status: { true }, set: { $0 }),
            approval: Approvals(["github", "claude-code", "oncall"]))
        let entitlements = EntitlementReader.file(at: file) ?? EntitlementReport(sandboxed: false, networkKeys: [])
        let now = Date(timeIntervalSince1970: 1_793_268_720)
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        let config = (try? ConfigStore.load(from: roots.config, fallbackZone: zone.identifier).0) ?? Config.defaults(timezone: zone.identifier)
        let sources = config.collectors.filter(\.enabled).map { collector in
            CollectorSource.make(
                collector: collector, failuresInARow: collector.name == "oncall" ? 3 : 0, lastError: nil,
                lastGoodRun: collector.name == "oncall" ? now.addingTimeInterval(-3 * 3600) : now.addingTimeInterval(-120),
                producedItems: true, now: now, zone: zone)
        }
        return SettingsModel(
            roots: roots, selfExecutable: helper, actions: actions, defaults: defaults, entitlements: entitlements,
            version: "Cadence 0.1", fileVault: .on, housekeeping: HousekeepingStatus(sources: sources),
            locale: Locale(identifier: "en_GB"), fallbackZone: zone.identifier,
            userHome: home, today: { today })
    }

    /// A store folder with an ACME config, a few backups and a database-sized file, under `home`.
    static func fixture(home root: URL) -> FileRoots {
        try? FileManager.default.removeItem(at: root)
        let home = root.appendingPathComponent("Library/Application Support/Cadence", isDirectory: true)
        let roots = FileRoots(home: home)
        for folder in roots.folders {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var config = Config.defaults(timezone: "Asia/Kolkata")
        config.reminders = [
            Config.Reminder(kind: .plan, after: "dayStart+2m"), Config.Reminder(kind: .wrap, at: "17:30"),
            Config.Reminder(kind: .wrap, at: "18:00"),
        ]
        config.collectors = [
            Config.Collector(name: "claude-code", builtin: "claude-code-transcripts", every: "60m"),
            Config.Collector(
                name: "genai-endpoint",
                command: ["/usr/bin/curl", "-fsS", "--max-time", "20", "http://127.0.0.1:8080/usage?from={since}&to={until}"],
                map: "maps/genai-endpoint.json", at: ["17:10"]),
            Config.Collector(
                name: "github", builtin: "github", env: ["GH_HOST": "git.example.com"], gh: "/opt/homebrew/bin/gh", every: "30m"),
            Config.Collector(name: "oncall", command: ["/Users/you/bin/acme-oncall.sh", "{since}", "{until}"], every: "60m"),
        ]
        try? ConfigStore.save(config, to: roots.config)
        FileManager.default.createFile(atPath: roots.database.path, contents: Data(count: 4_312_000))
        for day in ["2026-10-29", "2026-10-28", "2026-10-27"] {
            FileManager.default.createFile(atPath: roots.backups.appendingPathComponent("cadence-\(day).db").path, contents: Data())
        }
        return roots
    }
}
