// First run, all six steps (docs/SPEC.md section 4.6), from an empty store with an ACME config, so GitHub offers its
// exact command and History finds a map. Each optional step is shown before its action. Shared by `make token-sheet`
// and the snapshot suite. Nothing reads the real store.
import CadenceCore
import Foundation

@MainActor
public enum FirstRunSpecimens {
    /// One model per step, in step order, over one fixture under `home`.
    public static func models(home: URL, defaultsSuite: String = "cadence.token-sheet.firstrun") -> [FirstRunModel] {
        let roots = fixture(home: home)
        let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
        defaults.removePersistentDomain(forName: defaultsSuite)
        return FirstRunStep.allCases.map { step in
            FirstRunModel(
                roots: roots, selfExecutable: SettingsSpecimens.helper,
                actions: FirstRunActions(
                    loginItem: LoginItemControl(status: { true }, set: { $0 }),
                    notifications: NotificationControl(status: { .notAsked }, request: { .allowed }),
                    approval: SettingsSpecimens.Approvals([]), copy: { _ in }),
                defaults: defaults, fileVault: .on, fallbackZone: "Asia/Kolkata", userHome: home, startAt: step)
        }
    }

    /// An empty store: only config.json with the GitHub source, and one map.
    static func fixture(home: URL) -> FileRoots {
        try? FileManager.default.removeItem(at: home)
        let roots = FileRoots(home: home.appendingPathComponent("Library/Application Support/Cadence", isDirectory: true))
        try? FileManager.default.createDirectory(at: roots.maps, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var config = Config.defaults(timezone: "Asia/Kolkata")
        config.collectors = [
            Config.Collector(name: "github", builtin: "github", env: ["GH_HOST": "git.example.com"], gh: "/opt/homebrew/bin/gh", every: "30m")
        ]
        try? ConfigStore.save(config, to: roots.config)
        FileManager.default.createFile(atPath: roots.maps.appendingPathComponent("october-app.json").path, contents: Data("{}".utf8))
        return roots
    }
}
