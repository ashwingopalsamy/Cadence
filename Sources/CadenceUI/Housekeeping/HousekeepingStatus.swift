import CadenceCore
import Foundation

/// The background jobs the app runs for itself (docs/SPEC.md section 8.1).
public enum HousekeepingJob: String, Sendable, CaseIterable, Hashable {
    /// Hook lines in `spool/` become `genai.session` events.
    case spoolDrain
    /// Today's snapshot of the store, then retention.
    case backup
    /// Whether the collector agent is registered and allowed to run.
    case agent
    /// How each configured collector has been doing.
    case collectors
}

/// When a job last worked, when it last did not, and what its latest run said. The message is a count or a reason,
/// never an entry's title or note.
public struct JobHealth: Sendable, Equatable {
    public var lastSuccess: Date?
    public var lastFailure: Date?
    public var message: String?
    /// Whether the latest run failed. A failure is cleared by the next success.
    public var isFailing: Bool

    public init(lastSuccess: Date? = nil, lastFailure: Date? = nil, message: String? = nil, isFailing: Bool = false) {
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
        self.message = message
        self.isFailing = isFailing
    }

    mutating func succeeded(at instant: Date, message: String?) {
        lastSuccess = instant
        self.message = message
        isFailing = false
    }

    mutating func failed(at instant: Date, message: String) {
        lastFailure = instant
        self.message = message
        isFailing = true
    }
}

/// What the collector agent's registration with macOS says.
public enum AgentRegistration: String, Sendable, Equatable {
    case enabled
    /// Registered, and waiting for the owner to allow it in System Settings, General, Login Items.
    case requiresApproval
    case notRegistered
    /// The agent's plist is not in the app.
    case notFound
}

/// What the daily backup did, in the words the app needs.
public struct BackupOutcome: Sendable, Equatable {
    /// False when today's backup already existed.
    public var created: Bool
    public var day: String?
    public var events: Int64?
    /// Old backups retention removed.
    public var pruned: Int

    public init(created: Bool, day: String?, events: Int64?, pruned: Int) {
        self.created = created
        self.day = day
        self.events = events
        self.pruned = pruned
    }
}

/// One configured collector as the app sees it: its health, and whether it feeds the day's count.
public struct CollectorSource: Sendable, Equatable {
    /// Three failed runs in a row make a collector failing, and three runs without a good one make it overdue
    /// (docs/SPEC.md sections 5.2 and 10.2).
    public static let overdueRuns = 3

    /// As configured.
    public var name: String
    /// As spoken in the day's sentences: "GitHub".
    public var title: String
    /// Whether it produces items the day counts. AI usage is a tool, not an outcome, so it never does.
    public var feedsCount: Bool
    public var failuresInARow: Int
    public var lastError: String?
    public var lastGoodRun: Date?
    /// Local clock time of the last good run, such as "13:40", or "-" when there has been none.
    public var lastSync: String
    public var isFailing: Bool
    public var isOverdue: Bool

    /// A source that feeds the count and is failing or overdue: the day's numbers may be low (section 5.2).
    public var isBehind: Bool { feedsCount && (isFailing || isOverdue) }

    public init(
        name: String, title: String, feedsCount: Bool, failuresInARow: Int, lastError: String?, lastGoodRun: Date?,
        lastSync: String, isFailing: Bool, isOverdue: Bool
    ) {
        self.name = name
        self.title = title
        self.feedsCount = feedsCount
        self.failuresInARow = failuresInARow
        self.lastError = lastError
        self.lastGoodRun = lastGoodRun
        self.lastSync = lastSync
        self.isFailing = isFailing
        self.isOverdue = isOverdue
    }

    /// Pure: the facts the ledger gave, and the decisions on them.
    ///
    /// - `producedItems`: the collector has written an accepted entry that the day counts. GitHub feeds the count from
    ///   its first run; a command collector only once it has produced something, because it may report AI usage alone.
    /// - Overdue: the last good run is older than three of the collector's own periods, `every`, or a day split by the
    ///   number of `at` times. A collector that only runs when asked has no period, and one that never ran well has
    ///   nothing to be late against.
    public static func make(
        collector: Config.Collector, failuresInARow: Int, lastError: String?, lastGoodRun: Date?, producedItems: Bool,
        now: Date, zone: TimeZone
    ) -> CollectorSource {
        let period: TimeInterval? =
            collector.everyMinutes.map { Double($0) * 60 } ?? (collector.at.isEmpty ? nil : 86_400 / Double(collector.at.count))
        var overdue = false
        if let period, let lastGoodRun {
            overdue = now.timeIntervalSince(lastGoodRun) > Double(overdueRuns) * period
        }
        return CollectorSource(
            name: collector.name, title: title(of: collector), feedsCount: collector.builtin == "github" || producedItems,
            failuresInARow: failuresInARow, lastError: lastError, lastGoodRun: lastGoodRun,
            lastSync: lastGoodRun.map { Timestamp.clockTime($0, in: zone) } ?? "-",
            isFailing: failuresInARow >= CollectorHealth.failuresBeforeError, isOverdue: overdue)
    }

    static func title(of collector: Config.Collector) -> String {
        switch collector.builtin {
        case "github": String(localized: "GitHub")
        case "claude-code-transcripts": String(localized: "Claude Code")
        default: collector.name
        }
    }
}

/// Everything housekeeping knows, for Settings and for the day's story.
public struct HousekeepingStatus: Sendable, Equatable {
    public var jobs: [HousekeepingJob: JobHealth]
    public var agentRegistration: AgentRegistration?
    /// The last reading of the configured collectors.
    public var sources: [CollectorSource]

    public init(
        jobs: [HousekeepingJob: JobHealth] = Dictionary(uniqueKeysWithValues: HousekeepingJob.allCases.map { ($0, JobHealth()) }),
        agentRegistration: AgentRegistration? = nil, sources: [CollectorSource] = []
    ) {
        self.jobs = jobs
        self.agentRegistration = agentRegistration
        self.sources = sources
    }

    /// The source that feeds the count and is behind, for `AppSignals.behind`: its name and the clock time of its last
    /// good run. With several, the one silent longest. Nil when none is, and then no comparison is held back.
    public var behind: DayStory.Behind? {
        let behind = sources.filter(\.isBehind).sorted {
            ($0.lastGoodRun ?? .distantPast, $0.name) < ($1.lastGoodRun ?? .distantPast, $1.name)
        }
        return behind.first.map { DayStory.Behind(source: $0.title, lastSync: $0.lastSync) }
    }
}
