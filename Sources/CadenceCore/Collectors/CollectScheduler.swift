import Foundation

/// One collector run the scheduler made, and what became of it.
public struct CollectStep: Sendable, Equatable {
    public let collector: String
    public let window: IngestWindow
    public let result: CollectorRunResult

    /// True when the run did not happen or its `ingest.run` says error.
    public var failed: Bool {
        switch result {
        case .refused: true
        case .ran(let report): report.status != "ok"
        }
    }

    /// True when another run held a lock, so the request may be retried later.
    var wasBusy: Bool { result == .refused(.alreadyRunning) || result == .refused(.anotherRunning) }
}

/// A request the app dropped in `jobs/`. The file format is described in docs/SPEC.md section 10.2.
public enum CollectJob: Sendable, Equatable {
    case run(name: String)
    case backfill(name: String, from: LocalDate?)

    static func parse(_ bytes: [UInt8]) -> CollectJob? {
        guard let root = try? JSONParser.parse(bytes: bytes), let object = root.objectValue,
            let kind = object["job"]?.stringValue, let name = object["name"]?.stringValue, Actor.isValidName(name)
        else { return nil }
        switch kind {
        case "run":
            return object.count == 2 ? .run(name: name) : nil
        case "backfill":
            guard Set(object.keys).isSubset(of: ["job", "name", "from"]) else { return nil }
            guard let from = object["from"] else { return .backfill(name: name, from: nil) }
            guard let text = from.stringValue, let day = LocalDate(text), day >= CollectScheduler.earliestDay else { return nil }
            return .backfill(name: name, from: day)
        default:
            return nil
        }
    }
}

/// What happened to one file in `jobs/`.
public struct CollectJobOutcome: Sendable, Equatable {
    public let file: String
    /// Nil when the file was not a valid job.
    public let job: CollectJob?
    public let steps: [CollectStep]
    /// True when the file was removed. A job that met a busy lock is kept for the next tick.
    public let removed: Bool
}

/// Decides which collectors are due and which window each one asks for (docs/SPEC.md section 10.2). Time comes from the
/// injected clock; the only state is the ledger's own `ingest.run` events and the files in `jobs/`.
///
/// Windows are whole days in the profile zone (YYYY-MM-DD). The collectors already read days that way, and a day edge
/// cannot drift with the minute a run happened, so the 3-day overlap always lands on day boundaries.
public struct CollectScheduler {
    public static let overlapDays = 3
    public static let chunkDays = 7
    /// No backfill or explicit window may start before this day.
    public static let earliestDay = LocalDate("2000-01-01")!
    static let maxJobBytes = 4096

    let runner: CollectorRunner
    let journal: Journal
    let roots: FileRoots
    let clock: any Clock

    public init(runner: CollectorRunner, journal: Journal, roots: FileRoots, clock: any Clock) {
        self.runner = runner
        self.journal = journal
        self.roots = roots
        self.clock = clock
    }

    var zone: TimeZone { TimeZone(identifier: journal.config.profile.timezone) ?? TimeZone(identifier: "UTC") ?? .current }

    /// The workday now, by the configured day boundary (04:00 by default), as everywhere else. A window that ends
    /// "today" therefore still names the previous day until the boundary has passed.
    public func today() -> LocalDate { journal.config.dayBoundary.day(of: clock.now(), in: zone) }

    /// The calendar day of an instant in a zone.
    static func day(of instant: Date, in zone: TimeZone) -> LocalDate {
        LocalDate.fromEpochDays(LocalDate.floorDiv(Timestamp.localSeconds(instant, in: zone), 86_400))
    }

    // MARK: - History

    /// When a collector last ran (any status) and the furthest day it has read successfully.
    public struct History: Sendable, Equatable {
        public var lastRun: Date?
        public var lastStatus: String?
        public var lastOkUntil: LocalDate?
    }

    public func history(name: String) throws(CadenceError) -> History {
        let actor = SQLValue.text(Actor.collector(name).rawValue)
        var history = History()
        do {
            // The latest run of any status, and then every distinct `until` of the successful ones. Neither query has
            // a limit, so a long streak of failures cannot push the last good run out of view.
            if let row = try journal.store.db.first(
                """
                SELECT at, json_extract(data, '$.status') AS status FROM events
                WHERE type = 'ingest.run' AND actor = ? ORDER BY seq DESC LIMIT 1
                """, [actor])
            {
                history.lastRun = row.text("at").flatMap(Timestamp.parse)
                history.lastStatus = row.text("status")
            }
            let edges = try journal.store.db.query(
                """
                SELECT DISTINCT json_extract(data, '$.window.until') AS until FROM events
                WHERE type = 'ingest.run' AND actor = ? AND json_extract(data, '$.status') = 'ok'
                """, [actor])
            for edge in edges {
                guard let text = edge.text("until"), let until = Self.day(ofEdge: text, in: zone) else { continue }
                if let known = history.lastOkUntil, known >= until { continue }
                history.lastOkUntil = until
            }
        } catch {
            throw error.cadenceError
        }
        return history
    }

    static func day(ofEdge edge: String, in zone: TimeZone) -> LocalDate? {
        if let day = LocalDate(edge) { return day }
        return Timestamp.parse(edge).map { day(of: $0, in: zone) }
    }

    // MARK: - Due

    /// A collector with `every` is due when it never ran or its last run, of any status, is that old. With `at`, it is
    /// due once per local day after each listed time, unless a run happened since that time today. With neither it
    /// runs only when asked. Disabled collectors are never due.
    public func isDue(_ collector: Config.Collector, history: History) -> Bool {
        guard collector.enabled else { return false }
        let now = clock.now()
        if let minutes = collector.everyMinutes {
            guard let last = history.lastRun else { return true }
            if now.timeIntervalSince(last) >= Double(minutes) * 60 { return true }
        }
        let day = today()
        for time in collector.at {
            guard let instant = Timestamp.instant(clockTime: time, on: day, in: zone), instant <= now else { continue }
            if history.lastRun.map({ $0 < instant }) ?? true { return true }
        }
        return false
    }

    public func dueCollectors() throws(CadenceError) -> [Config.Collector] {
        var due: [Config.Collector] = []
        for collector in journal.config.collectors where try isDue(collector, history: history(name: collector.name)) {
            due.append(collector)
        }
        return due
    }

    // MARK: - Windows

    /// The next incremental window: the last successful `until` minus 3 days through today. The first run ever starts
    /// at `profile.backfillFrom`, or 3 days back without one. A window longer than 7 days is run in chunks (`windows`).
    public func window(for name: String) throws(CadenceError) -> IngestWindow {
        let today = today()
        let start = try incrementalStart(name: name, today: today)
        return IngestWindow(since: start.description, until: today.description)
    }

    /// The incremental window as 7-day chunks, oldest first, so a laptop that was off for weeks catches up the way a
    /// backfill does.
    public func windows(for name: String) throws(CadenceError) -> [IngestWindow] {
        let today = today()
        return Self.chunks(from: try incrementalStart(name: name, today: today), through: today)
    }

    private func incrementalStart(name: String, today: LocalDate) throws(CadenceError) -> LocalDate {
        let start: LocalDate
        if let last = try history(name: name).lastOkUntil {
            start = last.adding(days: -Self.overlapDays)
        } else {
            start = journal.config.profile.backfillFrom ?? today.adding(days: -Self.overlapDays)
        }
        return min(start, today)
    }

    /// `from` through today in 7-day chunks, oldest first.
    public static func chunks(from: LocalDate, through today: LocalDate) -> [IngestWindow] {
        var out: [IngestWindow] = []
        var start = from
        while start <= today {
            let end = min(start.adding(days: chunkDays - 1), today)
            out.append(IngestWindow(since: start.description, until: end.description))
            start = end.adding(days: 1)
        }
        return out
    }

    // MARK: - Running

    /// The usual window, in 7-day chunks when it is longer, stopping at the first chunk that fails or is refused.
    public func runIncremental(name: String) throws(CadenceError) -> [CollectStep] {
        try run(name: name, windows: try windows(for: name))
    }

    /// Each due collector once, serially. A collector that fails or is refused does not stop the others.
    public func runDue() throws(CadenceError) -> [CollectStep] {
        var steps: [CollectStep] = []
        for collector in try dueCollectors() { steps += try runIncremental(name: collector.name) }
        return steps
    }

    /// Chunk by chunk from `from` (default `profile.backfillFrom`, then 3 days back), stopping at the first that fails.
    /// A start before 2000-01-01 or after today is refused.
    public func backfill(name: String, from: LocalDate?) throws(CadenceError) -> [CollectStep] {
        let today = today()
        let start = from ?? journal.config.profile.backfillFrom ?? today.adding(days: -Self.overlapDays)
        if from != nil { try Self.checkBackfillStart(start, today: today) }
        return try run(name: name, windows: Self.chunks(from: min(start, today), through: today))
    }

    /// Exactly `since` through `until`, in 7-day chunks when longer, stopping at the first chunk that fails. Needs
    /// 2000-01-01 <= since <= until <= today.
    public func runWindow(name: String, since: LocalDate, until: LocalDate) throws(CadenceError) -> [CollectStep] {
        try validateWindow(since: since, until: until)
        return try run(name: name, windows: Self.chunks(from: since, through: until))
    }

    /// Refuses a window that is backwards, ends after today or starts before 2000-01-01.
    public func validateWindow(since: LocalDate, until: LocalDate) throws(CadenceError) {
        let today = today()
        guard since <= until else { throw .validation("--since \(since) is after --until \(until)") }
        guard until <= today else { throw .validation("--until \(until) is in the future; today is \(today)") }
        guard since >= Self.earliestDay else { throw .validation("--since \(since) is before \(Self.earliestDay)") }
    }

    /// Refuses a backfill start before 2000-01-01 or after today.
    public func validateBackfillStart(_ start: LocalDate) throws(CadenceError) {
        try Self.checkBackfillStart(start, today: today())
    }

    static func checkBackfillStart(_ start: LocalDate, today: LocalDate) throws(CadenceError) {
        guard start >= earliestDay else { throw .validation("backfill: \(start) is before \(earliestDay)") }
        guard start <= today else { throw .validation("backfill: \(start) is in the future; today is \(today)") }
    }

    private func run(name: String, windows: [IngestWindow]) throws(CadenceError) -> [CollectStep] {
        var steps: [CollectStep] = []
        for window in windows {
            let step = CollectStep(collector: name, window: window, result: try runner.run(name: name, window: window))
            steps.append(step)
            if step.failed { break }
        }
        return steps
    }

    // MARK: - Jobs

    /// Handles every `*.json` file in `jobs/`, oldest first. A file goes away once its job was handled, whether it
    /// ran or was refused, or when it is not a valid job. A job that met a busy lock stays for the next tick.
    public func processJobs() throws(CadenceError) -> [CollectJobOutcome] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: roots.jobs.path)) ?? []
        var files: [(name: String, modified: Date)] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = roots.jobs.appendingPathComponent(name).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
            files.append((name, modified))
        }
        files.sort { ($0.modified, $0.name) < ($1.modified, $1.name) }

        var outcomes: [CollectJobOutcome] = []
        for file in files {
            let url = roots.jobs.appendingPathComponent(file.name)
            guard let bytes = PrivateFile.readOwned(url, limit: Self.maxJobBytes), let job = CollectJob.parse(bytes) else {
                outcomes.append(CollectJobOutcome(file: file.name, job: nil, steps: [], removed: unlink(url.path) == 0))
                continue
            }
            if case .backfill(_, let from?) = job, from > today() {
                outcomes.append(CollectJobOutcome(file: file.name, job: nil, steps: [], removed: unlink(url.path) == 0))
                continue
            }
            let steps: [CollectStep]
            switch job {
            case .run(let name): steps = try runIncremental(name: name)
            case .backfill(let name, let from): steps = try backfill(name: name, from: from)
            }
            let keep = steps.contains { $0.wasBusy }
            outcomes.append(CollectJobOutcome(file: file.name, job: job, steps: steps, removed: !keep && unlink(url.path) == 0))
        }
        return outcomes
    }
}
