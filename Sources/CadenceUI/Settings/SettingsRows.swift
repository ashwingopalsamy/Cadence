// Settings as data (docs/SPEC.md section 4.6): every pane is a list of rows built by one pure function from the
// config, the app's preferences and what the app knows about its store, sources and signature. The view only draws
// rows, so tests read exactly what a pane shows.
import CadenceCore
import Foundation

public enum SettingsPane: String, CaseIterable, Sendable, Identifiable {
    case general = "General"
    case reminders = "Reminders"
    case capture = "Capture"
    case sources = "Sources"
    case tickets = "Tickets"
    case privacy = "Privacy"
    case data = "Data"
    case about = "About"

    public var id: String { rawValue }
    /// The raw value is the pane's identifier, so a window can open it by name; the title is what people read.
    public var title: String {
        switch self {
        case .general: String(localized: "General")
        case .reminders: String(localized: "Reminders")
        case .capture: String(localized: "Capture")
        case .sources: String(localized: "Sources")
        case .tickets: String(localized: "Tickets")
        case .privacy: String(localized: "Privacy")
        case .data: String(localized: "Data")
        case .about: String(localized: "About")
        }
    }
}

/// The switches Settings can flip.
public enum SettingsToggle: String, Sendable, Hashable {
    case openAtLogin, showTempo, showStreak, discreet, agentSound
    case notificationTitles, remindOnWeekends, afterWrapUp, hideTitlesOnLockScreen
}

public enum SettingsButton: String, Sendable, Hashable {
    case backUpNow, showInFinder, restore
}

/// What a source does next, one action per row (section 4.6: Approve, Run now or Details).
public enum SourceAction: String, Sendable, Hashable {
    case approve, runNow, details
}

/// One configured collector as Settings shows it.
public struct SourceRow: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        /// Approved and running well; the text is its last run, such as "Synced 13:40" or "Not run yet".
        case ok(String)
        /// New, or changed since you approved it.
        case needsApproval
        /// Approved but failing or behind; the text says how.
        case failing(String)
        /// `enabled: false` in config.json.
        case off
        /// Core cannot build its command; the text is why.
        case invalid(String)
    }

    public var name: String
    public var title: String
    /// The exact argv on one line, placeholders in place. Empty when the command is invalid.
    public var command: String
    /// Every argument quoted on its own line, then the environment: what Approve shows (section 10.2).
    public var approvalText: String?
    /// What it reads, and when it runs.
    public var reads: String
    public var state: State
    public var action: SourceAction
    public var plan: CollectorPlan?

    public var id: String { name }

    /// The words for the state, as the row prints them.
    public var stateText: String {
        switch state {
        case .ok(let text), .failing(let text): text
        case .needsApproval: String(localized: "Needs approval")
        case .off: String(localized: "Off in config.json")
        case .invalid: String(localized: "Cannot run")
        }
    }
}

public enum SettingsRow: Sendable, Equatable, Identifiable {
    case toggle(SettingsToggle, title: String, detail: String?, isOn: Bool, enabled: Bool)
    case value(id: String, title: String, detail: String?, value: String, mono: Bool)
    case sound(Config.Sounds)
    /// Wrap-up reminder times as chips: the presets, then any other time in the config, and "Add time".
    case wrapTimes(selected: [String], shown: [String])
    case hotkey(HotkeyBinding, title: String)
    /// A finding in a coloured strip: good, or a problem in `warn`.
    case status(id: String, text: String, good: Bool)
    case hint(String)
    case source(SourceRow)
    case buttons([SettingsButton])
    case aboutHeader(version: String)

    public var id: String {
        switch self {
        case .toggle(let key, _, _, _, _): "toggle.\(key.rawValue)"
        case .value(let id, _, _, _, _): "value.\(id)"
        case .sound: "sound"
        case .wrapTimes: "wrapTimes"
        case .hotkey(let binding, _): "hotkey.\(binding.action.rawValue)"
        case .status(let id, _, _): "status.\(id)"
        case .hint(let text): "hint.\(text)"
        case .source(let row): "source.\(row.name)"
        case .buttons: "buttons"
        case .aboutHeader: "about"
        }
    }
}

/// The store as the Data pane describes it.
public struct StoreFacts: Sendable, Equatable {
    public var folder: URL
    /// The folder as a person writes it: `~/Library/Application Support/Cadence`.
    public var display: String
    /// The database with its WAL and shared memory files. Nil when it could not be read.
    public var bytes: Int64?
    /// Backup days, newest first.
    public var backups: [LocalDate]
    /// `.json` files in `maps/`, sorted.
    public var maps: [String]

    public init(folder: URL, display: String, bytes: Int64?, backups: [LocalDate], maps: [String]) {
        self.folder = folder
        self.display = display
        self.bytes = bytes
        self.backups = backups
        self.maps = maps
    }

    /// Reads sizes and names only; it never opens the database.
    public static func read(_ roots: FileRoots, userHome: URL = SettingsFormat.userHome) -> StoreFacts {
        let manager = FileManager.default
        var total: Int64 = 0
        var found = false
        for suffix in ["", String(localized: "-wal"), String(localized: "-shm")] {
            let path = roots.database.path + suffix
            if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                total += size.int64Value
                found = true
            }
        }
        let backups = ((try? manager.contentsOfDirectory(atPath: roots.backups.path)) ?? [])
            .compactMap(Backups.day(fromFileName:)).sorted(by: >)
        let maps = ((try? manager.contentsOfDirectory(atPath: roots.maps.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return StoreFacts(
            folder: roots.home, display: SettingsFormat.abbreviate(roots.home, home: userHome), bytes: found ? total : nil,
            backups: backups, maps: maps)
    }
}

/// Everything a pane is built from, as one value.
public struct SettingsSnapshot: Sendable, Equatable {
    public var config: Config
    /// Why config.json cannot be trusted or read, in the words `ConfigStore` gives. Sources are off while it is set.
    public var configProblem: String?
    public var preferences: AppPreferences
    public var discreet: Bool
    /// Nil when macOS cannot say.
    public var openAtLogin: Bool?
    public var housekeeping: HousekeepingStatus
    public var clashes: [HotkeyClash]
    /// The cadence binary the agent runs, which built-in collectors' commands start with.
    public var selfExecutable: String
    /// Collector names whose current command is approved.
    public var approved: Set<String>
    public var fileVault: FileVaultState
    public var entitlements: EntitlementReport
    public var version: String
    public var store: StoreFacts
    public var today: LocalDate
    public var locale: Locale

    public init(
        config: Config, configProblem: String? = nil, preferences: AppPreferences = AppPreferences(), discreet: Bool = false,
        openAtLogin: Bool? = nil, housekeeping: HousekeepingStatus = HousekeepingStatus(), clashes: [HotkeyClash] = [],
        selfExecutable: String, approved: Set<String> = [], fileVault: FileVaultState = .unknown,
        entitlements: EntitlementReport, version: String, store: StoreFacts, today: LocalDate, locale: Locale = .current
    ) {
        self.config = config
        self.configProblem = configProblem
        self.preferences = preferences
        self.discreet = discreet
        self.openAtLogin = openAtLogin
        self.housekeeping = housekeeping
        self.clashes = clashes
        self.selfExecutable = selfExecutable
        self.approved = approved
        self.fileVault = fileVault
        self.entitlements = entitlements
        self.version = version
        self.store = store
        self.today = today
        self.locale = locale
    }
}

public enum SettingsRows {
    public static let wrapPresets = ["16:00", "17:30", "18:00"]
    public static let sourcesRule = String(localized: "A source only runs after you approve its exact command.")

    public static func rows(_ pane: SettingsPane, _ s: SettingsSnapshot) -> [SettingsRow] {
        switch pane {
        case .general: general(s)
        case .reminders: reminders(s)
        case .capture: capture(s)
        case .sources: sources(s)
        case .tickets: tickets(s)
        case .privacy: privacy(s)
        case .data: data(s)
        case .about: about(s)
        }
    }

    static func general(_ s: SettingsSnapshot) -> [SettingsRow] {
        [
            .toggle(
                .openAtLogin, title: String(localized: "Open Cadence at login"),
                detail: s.openAtLogin == nil
                    ? String(localized: "macOS did not say whether Cadence opens at login.") : String(localized: "Cadence keeps your day running in the background."),
                isOn: s.openAtLogin ?? false, enabled: s.openAtLogin != nil),
            .toggle(
                .showTempo, title: String(localized: "Show Tempo"), detail: String(localized: "The little metronome. Everything still works without it."),
                isOn: s.preferences.showTempo, enabled: true),
            .toggle(
                .showStreak, title: String(localized: "Show my streak"), detail: String(localized: "Appears only in Insights. Reminders never mention it."),
                isOn: s.preferences.showStreak, enabled: true),
            .toggle(
                .discreet, title: String(localized: "Discreet mode"),
                detail: String(localized: "Hides titles and Tempo, for screen sharing. Press \(s.preferences.hotkeys.discreet.display)."),
                isOn: s.discreet, enabled: true),
            .sound(s.config.sounds),
            .toggle(
                .agentSound, title: String(localized: "Sound when an agent logs work"), detail: String(localized: "Off unless you turn it on."),
                isOn: s.preferences.agentSound, enabled: s.config.sounds != .off),
            .value(id: "menuBarIcon", title: String(localized: "Menu-bar icon"), detail: nil, value: String(localized: "Icon only"), mono: false),
        ]
    }

    static func reminders(_ s: SettingsSnapshot) -> [SettingsRow] {
        let wraps = s.config.reminders.filter { $0.kind == .wrap }.compactMap(\.at)
        let extra = Set(wraps).subtracting(wrapPresets).sorted()
        return [
            .hint(String(localized: "Reminders never mention your streak, and never use titles unless you ask.")),
            .value(id: "plan", title: String(localized: "Plan prompt"), detail: nil, value: planPrompt(s), mono: false),
            .wrapTimes(selected: wraps.sorted(), shown: wrapPresets + extra),
            .toggle(
                .notificationTitles, title: String(localized: "Show task titles in notifications"), detail: String(localized: "Off shows counts only."),
                isOn: s.config.privacy.notificationTitles, enabled: true),
            .toggle(.remindOnWeekends, title: String(localized: "Remind me on weekends"), detail: nil, isOn: s.preferences.remindOnWeekends, enabled: true),
            .value(
                id: "dayEnds", title: String(localized: "Day ends at"), detail: String(localized: "Work after midnight still counts for the day before."),
                value: SettingsFormat.clock(hour: s.config.dayBoundary.hour, minute: s.config.dayBoundary.minute, locale: s.locale),
                mono: false),
        ]
    }

    static func planPrompt(_ s: SettingsSnapshot) -> String {
        guard let plan = s.config.reminders.first(where: { $0.kind == .plan }) else { return String(localized: "Off") }
        if let at = plan.at, let clock = SettingsFormat.parseClock(at) {
            return SettingsFormat.clock(hour: clock.0, minute: clock.1, locale: s.locale)
        }
        if let after = plan.after, after.hasPrefix("dayStart+") {
            let amount = after.dropFirst("dayStart+".count)
            let unit = amount.last == "h" ? (amount.dropLast() == "1" ? String(localized: "hour") : String(localized: "hours")) : String(localized: "min")
            return String(localized: "\(amount.dropLast()) \(unit) after your day starts")
        }
        return String(localized: "When your day starts")
    }

    static func capture(_ s: SettingsSnapshot) -> [SettingsRow] {
        let keys = s.preferences.hotkeys
        var rows: [SettingsRow] = [
            .hotkey(keys.capture, title: String(localized: "Capture hotkey")),
            .hotkey(keys.quickNote, title: String(localized: "Quick note")),
            .hotkey(keys.discreet, title: String(localized: "Discreet mode")),
        ]
        for clash in s.clashes { rows.append(.status(id: "clash.\(clash.binding.action.rawValue)", text: clash.message, good: false)) }
        rows += [
            .toggle(
                .afterWrapUp, title: String(localized: "Mark entries added after wrap-up"), detail: String(localized: "Always on, so your proof stays honest."),
                isOn: true, enabled: false),
            .value(id: "defaultKind", title: String(localized: "Default kind"), detail: String(localized: "When a line names no kind of work."), value: String(localized: "Note"), mono: false),
        ]
        return rows
    }

    static func sources(_ s: SettingsSnapshot) -> [SettingsRow] {
        var rows: [SettingsRow] = [.hint(sourcesRule)]
        if let problem = s.configProblem { rows.append(.status(id: "config", text: String(localized: "Sources are off. \(problem)"), good: false)) }
        if s.config.collectors.isEmpty {
            rows.append(.hint(String(localized: "No sources yet. Add one to config.json and it appears here for approval.")))
        }
        rows += sourceRows(s).map(SettingsRow.source)
        return rows
    }

    public static func sourceRows(_ s: SettingsSnapshot) -> [SourceRow] {
        s.config.collectors.map { collector in
            let title = CollectorSource.title(of: collector)
            let reads = "\(schedule(collector)). \(SettingsFormat.reads(collector))"
            let plan: CollectorPlan
            do throws(CadenceError) {
                plan = try CollectorRunner.plan(for: collector, selfExecutable: s.selfExecutable)
            } catch {
                return SourceRow(
                    name: collector.name, title: title, command: "", approvalText: nil, reads: reads,
                    state: .invalid(error.message), action: .details, plan: nil)
            }
            let command = ([plan.executable] + plan.arguments).joined(separator: " ")
            let state: SourceRow.State
            let action: SourceAction
            if !collector.enabled {
                (state, action) = (.off, .details)
            } else if !s.approved.contains(collector.name) {
                (state, action) = (.needsApproval, .approve)
            } else if let health = s.housekeeping.sources.first(where: { $0.name == collector.name }) {
                if health.isFailing {
                    (state, action) = (.failing(String(localized: "Failed \(health.failuresInARow) times in a row")), .runNow)
                } else if health.isOverdue {
                    (state, action) = (.failing(String(localized: "Behind, last synced \(health.lastSync)")), .runNow)
                } else if health.lastGoodRun == nil {
                    (state, action) = (.ok(String(localized: "Not run yet")), .details)
                } else {
                    (state, action) = (.ok(String(localized: "Synced \(health.lastSync)")), .details)
                }
            } else {
                (state, action) = (.ok(String(localized: "Not run yet")), .details)
            }
            return SourceRow(
                name: collector.name, title: title, command: command, approvalText: plan.approvalText, reads: reads,
                state: state, action: action, plan: plan)
        }
    }

    static func schedule(_ collector: Config.Collector) -> String {
        if let minutes = collector.everyMinutes {
            return minutes % 60 == 0 ? String(localized: "Every \(minutes / 60 == 1 ? String(localized: "hour") : String(localized: "\(minutes / 60) hours"))") : String(localized: "Every \(minutes) min")
        }
        if !collector.at.isEmpty { return String(localized: "Daily at \(collector.at.joined(separator: ", "))") }
        return String(localized: "Only when you ask")
    }

    static func tickets(_ s: SettingsSnapshot) -> [SettingsRow] {
        let rules = s.config.tickets
        var rows: [SettingsRow] = [
            .value(id: "pattern", title: String(localized: "Assigned pattern"), detail: String(localized: "A ticket key in a PR title counts as assigned."), value: rules.pattern, mono: true),
            .value(
                id: "selfInitiated", title: String(localized: "Self-started rule"), detail: String(localized: "A ticket number that matches this counts as self-started."),
                value: rules.selfInitiated, mono: true),
            .value(
                id: "titleWindow", title: String(localized: "Where to look"), detail: nil,
                value: String(localized: "The first \(rules.titleWindow) characters of a PR title"), mono: false),
        ]
        if let example = example(rules) { rows.append(.hint(example)) }
        return rows
    }

    /// Example keys checked against the configured rules, so the hint never claims what the classifier would not do.
    static func example(_ rules: TicketRules) -> String? {
        guard let classifier = try? TicketClassifier(rules: rules) else { return nil }
        var parts: [String] = []
        if let assigned = classifier.firstTicket(in: "ACME-482913"), !assigned.selfInitiated {
            parts.append(String(localized: "\(assigned.key) counts as assigned"))
        }
        if let started = classifier.firstTicket(in: "ACME-000000"), started.selfInitiated {
            parts.append(String(localized: "\(started.key) counts as self-started"))
        }
        guard !parts.isEmpty else { return nil }
        return String(localized: "Example: \(parts.joined(separator: ", and ")). A PR with no ticket counts as neither.")
    }

    static func privacy(_ s: SettingsSnapshot) -> [SettingsRow] {
        let vault: (String, String?) =
            switch s.fileVault {
            case .on: (String(localized: "FileVault is on"), nil)
            case .off: (String(localized: "FileVault is off"), String(localized: "Turn it on in System Settings, Privacy & Security, FileVault."))
            case .unknown: ("-", String(localized: "Cadence could not read it. Run cadence doctor to check."))
            }
        return [
            .value(
                id: "privateNotes", title: String(localized: "Private notes"), detail: String(localized: "Private notes only ever appear in a proof as a digest."),
                value: String(localized: "Always private"), mono: false),
            .toggle(
                .hideTitlesOnLockScreen, title: String(localized: "Hide titles on the lock screen"),
                detail: s.config.privacy.notificationTitles
                    ? String(localized: "Titles show only while your Mac is unlocked.") : String(localized: "Notifications show counts only, so there is nothing to hide."),
                isOn: s.preferences.hideTitlesOnLockScreen, enabled: s.config.privacy.notificationTitles),
            .value(id: "presence", title: String(localized: "Presence"), detail: nil, value: String(localized: "Timestamps only, never apps or window titles"), mono: false),
            .value(id: "fileVault", title: String(localized: "Encrypted at rest"), detail: vault.1, value: vault.0, mono: false),
        ]
    }

    static func data(_ s: SettingsSnapshot) -> [SettingsRow] {
        let latest: String
        if let day = s.store.backups.first {
            latest = String(localized: "\(SettingsFormat.day(day, today: s.today, locale: s.locale)). \(Backups.dailyKept) daily and \(Backups.weeklyKept) weekly kept.")
        } else {
            latest = String(localized: "None yet. \(Backups.dailyKept) daily and \(Backups.weeklyKept) weekly are kept.")
        }
        return [
            .value(id: "folder", title: String(localized: "Your log"), detail: nil, value: s.store.display, mono: false),
            .value(id: "size", title: String(localized: "Size"), detail: nil, value: s.store.bytes.map { SettingsFormat.bytes($0, locale: s.locale) } ?? "-", mono: false),
            .value(id: "backup", title: String(localized: "Latest backup"), detail: nil, value: latest, mono: false),
            .buttons([.backUpNow, .showInFinder, .restore]),
            .hint(String(localized: "Quitting never deletes anything, and uninstalling leaves your data in place.")),
        ]
    }

    static func about(_ s: SettingsSnapshot) -> [SettingsRow] {
        [
            .aboutHeader(version: s.version),
            .value(id: "network", title: String(localized: "Network calls by this app"), detail: nil, value: s.entitlements.networkSummary, mono: false),
            .value(id: "sourcesNetwork", title: String(localized: "Network calls by approved sources"), detail: nil, value: approvedNetwork(s), mono: false),
            .value(id: "sandbox", title: String(localized: "App sandbox"), detail: nil, value: s.entitlements.sandboxed ? String(localized: "On") : String(localized: "Off"), mono: false),
            .value(id: "fonts", title: String(localized: "Fonts"), detail: nil, value: String(localized: "Geist Mono, SIL OFL 1.1"), mono: false),
        ]
    }

    /// What each approved, enabled source talks to, as far as its config says.
    static func approvedNetwork(_ s: SettingsSnapshot) -> String {
        let parts = s.config.collectors.filter { $0.enabled && s.approved.contains($0.name) }.compactMap { collector -> String? in
            switch collector.builtin {
            case "github": "gh to \(collector.env["GH_HOST"] ?? "github.com")"
            case "claude-code-transcripts": nil
            default: collector.command?.first.map { URL(fileURLWithPath: $0).lastPathComponent }
            }
        }
        return parts.isEmpty ? String(localized: "None") : parts.joined(separator: ", ")
    }
}

/// Small formatting rules shared by Settings and first run. Times and dates follow the locale (section 6.6).
public enum SettingsFormat {
    /// The account's home, not the sandbox container's.
    public static var userHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    public static func abbreviate(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = home.standardizedFileURL.path
        var shown = path == base ? "~" : path.hasPrefix(base + "/") ? "~" + path.dropFirst(base.count) : path
        while shown.count > 1, shown.hasSuffix("/") { shown.removeLast() }
        return shown
    }

    static func parseClock(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    public static func clock(hour: Int, minute: Int, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let date = Date(timeIntervalSince1970: TimeInterval(hour * 3600 + minute * 60))
        return formatter.string(from: date)
    }

    /// "Today", "Yesterday" or the day and month.
    public static func day(_ day: LocalDate, today: LocalDate, locale: Locale) -> String {
        if day == today { return String(localized: "Today") }
        if day == today.adding(days: -1) { return String(localized: "Yesterday") }
        var components = DateComponents()
        (components.year, components.month, components.day) = (day.year, day.month, day.day)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else { return day.description }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(day.year == today.year ? "dMMM" : "dMMMy")
        return formatter.string(from: date)
    }

    public static func bytes(_ count: Int64, locale: Locale) -> String {
        count.formatted(.byteCount(style: .file).locale(locale))
    }

    /// What a collector reads, in one sentence.
    public static func reads(_ collector: Config.Collector) -> String {
        switch collector.builtin {
        case "github":
            String(localized: "Reads your PRs and reviews through gh on \(collector.env["GH_HOST"] ?? "github.com").")
        case "claude-code-transcripts":
            String(localized: "Reads token counts from Claude Code's transcripts on this Mac. No code or prompts.")
        default:
            collector.map.map { String(localized: "Reads what your command prints, through the map \($0).") }
                ?? String(localized: "Reads the envelope your command prints.")
        }
    }
}
