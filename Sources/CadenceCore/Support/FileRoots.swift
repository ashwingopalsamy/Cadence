import Foundation

/// Every path Cadence reads or writes, derived from one home folder (docs/SPEC.md section 7.4).
///
/// The home is `CADENCE_HOME` when set, otherwise `~/Library/Application Support/Cadence`
/// on macOS and `$XDG_DATA_HOME/cadence` (default `~/.local/share/cadence`) elsewhere.
public struct FileRoots: Sendable, Equatable {
    public let home: URL

    public init(home: URL) {
        self.home = home.standardizedFileURL
    }

    public var database: URL { home.appendingPathComponent("cadence.db") }
    public var config: URL { home.appendingPathComponent("config.json") }
    public var spool: URL { home.appendingPathComponent("spool", isDirectory: true) }
    public var jobs: URL { home.appendingPathComponent("jobs", isDirectory: true) }
    public var inbox: URL { home.appendingPathComponent("inbox", isDirectory: true) }
    public var exports: URL { home.appendingPathComponent("exports", isDirectory: true) }
    public var backups: URL { home.appendingPathComponent("backups", isDirectory: true) }
    public var logs: URL { home.appendingPathComponent("logs", isDirectory: true) }
    public var maps: URL { home.appendingPathComponent("maps", isDirectory: true) }
    public var state: URL { home.appendingPathComponent("state", isDirectory: true) }

    /// Subfolders created with mode 0700 on first use.
    public var folders: [URL] { [home, spool, jobs, inbox, exports, backups, logs, maps, state] }

    /// Resolves the home folder from an environment and the user's home directory.
    /// Pure: callers pass `ProcessInfo.processInfo.environment` and the real home.
    public static func resolve(environment: [String: String], userHome: URL) -> FileRoots {
        if let explicit = environment["CADENCE_HOME"], !explicit.isEmpty {
            return FileRoots(home: URL(fileURLWithPath: expandTilde(explicit, userHome: userHome), isDirectory: true))
        }
        #if os(macOS)
        let base = userHome.appendingPathComponent("Library/Application Support/Cadence", isDirectory: true)
        #else
        let xdg = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let dataHome = xdg.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? userHome.appendingPathComponent(".local/share", isDirectory: true)
        let base = dataHome.appendingPathComponent("cadence", isDirectory: true)
        #endif
        return FileRoots(home: base)
    }

    static func expandTilde(_ path: String, userHome: URL) -> String {
        if path == "~" { return userHome.path }
        if path.hasPrefix("~/") { return userHome.path + String(path.dropFirst(1)) }
        return path
    }
}
