import CadenceCore
import Foundation

/// What the jobs ask of the store. The app's writer does it; tests give a fake.
public protocol HousekeepingWork: Sendable {
    func drainSpool() async -> Result<DrainReport, StoreFailure>
    func runBackup() async -> Result<BackupOutcome, StoreFailure>
    func collectorSources() async -> Result<[CollectorSource], StoreFailure>
}

extension AppWriter: HousekeepingWork {}

/// Where the collector agent's registration is read from: `SMAppService` in the app.
public protocol AgentStatusReading: Sendable {
    func registration() -> AgentRegistration
}

/// How often each job runs. Every job also runs once at launch.
public struct HousekeepingSchedule: Sendable, Equatable {
    public var spoolEvery: TimeInterval
    /// Today's backup is made at most once a day, whenever this check first finds it missing.
    public var backupEvery: TimeInterval
    public var agentEvery: TimeInterval
    public var sourcesEvery: TimeInterval
    /// The least time between two runs of one job that a store-changed signal may start. The app's own writes signal
    /// too, so a burst is one run, and the schedule covers what the gap skipped.
    public var signalGap: TimeInterval

    public static let standard = HousekeepingSchedule(
        spoolEvery: 300, backupEvery: 3600, agentEvery: 900, sourcesEvery: 300, signalGap: 15)

    public init(spoolEvery: TimeInterval, backupEvery: TimeInterval, agentEvery: TimeInterval, sourcesEvery: TimeInterval, signalGap: TimeInterval) {
        self.spoolEvery = spoolEvery
        self.backupEvery = backupEvery
        self.agentEvery = agentEvery
        self.sourcesEvery = sourcesEvery
        self.signalGap = signalGap
    }

    func interval(of job: HousekeepingJob) -> TimeInterval {
        switch job {
        case .spoolDrain: spoolEvery
        case .backup: backupEvery
        case .agent: agentEvery
        case .collectors: sourcesEvery
        }
    }
}

/// The app's background jobs, each supervised: it runs at launch and on its own schedule, one run at a time, and a
/// failure is recorded as that job's health and never stops it or any other job (docs/SPEC.md section 8.1).
///
/// - Spool drain: at launch, every few minutes, and when the store changes.
/// - Backup: `Backups.runIfDue` and then retention, checked hourly, so a day's backup is made once, whenever the app is
///   first running on that workday.
/// - Agent: the registration status, read from `SMAppService` in the app.
/// - Collectors: each configured collector's health; `status.behind` is the app's `AppSignals.behind`.
///
/// Everything that touches the store goes through the app's writer, so no job opens a second write connection.
public final class Housekeeping: @unchecked Sendable {
    private let work: any HousekeepingWork
    private let agent: any AgentStatusReading
    private let signal: any StoreChangeSignal
    private let clock: any Clock
    private let schedule: HousekeepingSchedule
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let log: any AppLogSink

    private let lock = NSLock()
    private var handler: (@Sendable (HousekeepingStatus) -> Void)?
    private var current = HousekeepingStatus()
    private var loops: [Task<Void, Never>] = []
    private var running = Set<HousekeepingJob>()
    private var again = Set<HousekeepingJob>()
    private var lastStarted: [HousekeepingJob: Date] = [:]

    public init(
        work: any HousekeepingWork, agent: any AgentStatusReading, signal: any StoreChangeSignal = DarwinStoreChangeSignal(),
        clock: any Clock, schedule: HousekeepingSchedule = .standard,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in try? await Task.sleep(for: .seconds(seconds)) },
        onChange: (@Sendable (HousekeepingStatus) -> Void)? = nil, log: any AppLogSink = AppLog.system
    ) {
        self.work = work
        self.agent = agent
        self.signal = signal
        self.clock = clock
        self.schedule = schedule
        self.sleep = sleep
        self.log = log
        handler = onChange
    }

    /// Called with the new status after every run, from any thread. Set it where the app's signals are kept.
    public var onChange: (@Sendable (HousekeepingStatus) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    /// The latest health of every job, and the last reading of the sources.
    public var status: HousekeepingStatus { lock.withLock { current } }

    // MARK: Running

    /// Runs every job now and again on its schedule, and starts listening for store changes.
    public func start() {
        let started = lock.withLock { () -> Bool in
            guard loops.isEmpty else { return false }
            loops = HousekeepingJob.allCases.map { job in
                Task.detached { [self] in
                    while !Task.isCancelled {
                        await run(job)
                        await sleep(schedule.interval(of: job))
                    }
                }
            }
            return true
        }
        guard started else { return }
        signal.start { [weak self] in self?.storeChanged() }
    }

    public func stop() {
        signal.stop()
        let ended = lock.withLock { () -> [Task<Void, Never>] in
            defer { loops = [] }
            return loops
        }
        for loop in ended { loop.cancel() }
    }

    /// The store changed: from the app's own writes or another process's. The spool and the sources are what a change
    /// can affect.
    func storeChanged() {
        let now = clock.now()
        for job in [HousekeepingJob.spoolDrain, .collectors] {
            let due = lock.withLock { () -> Bool in
                if let last = lastStarted[job], now.timeIntervalSince(last) < schedule.signalGap { return false }
                return true
            }
            if due { Task.detached { [self] in await run(job) } }
        }
    }

    /// One run of one job, with its health recorded. While the job is already running, the ask is remembered and the
    /// job runs once more when it ends, so spool files are never drained by two runs at once.
    public func run(_ job: HousekeepingJob) async {
        let mine = lock.withLock { () -> Bool in
            if running.contains(job) {
                again.insert(job)
                return false
            }
            running.insert(job)
            return true
        }
        guard mine else { return }
        repeat {
            lock.withLock { lastStarted[job] = clock.now() }
            await runOnce(job)
        } while lock.withLock({ () -> Bool in
            if again.remove(job) != nil { return true }
            running.remove(job)
            return false
        })
    }

    /// What one run found: the words for the job's health, and any state it also changes.
    private struct Outcome {
        var message: String
        var ok: Bool
        /// Why it failed, as a fixed word for the log. Nil on success.
        var code: LogCode?
        var change: (inout HousekeepingStatus) -> Void = { _ in }

        init(message: String, code: LogCode? = nil, change: @escaping (inout HousekeepingStatus) -> Void = { _ in }) {
            self.message = message
            ok = code == nil
            self.code = code
            self.change = change
        }

        init(failure: StoreFailure) {
            self.init(message: failure.detail, code: LogCode(failure.kind))
        }
    }

    private func runOnce(_ job: HousekeepingJob) async {
        let watch = Stopwatch()
        let outcome: Outcome
        switch job {
        case .spoolDrain:
            switch await work.drainSpool() {
            case .success(let report): outcome = Outcome(message: report.summary)
            case .failure(let failure): outcome = Outcome(failure: failure)
            }
        case .backup:
            switch await work.runBackup() {
            case .success(let result): outcome = Outcome(message: Self.message(for: result))
            case .failure(let failure): outcome = Outcome(failure: failure)
            }
        case .agent:
            let registration = agent.registration()
            let (message, working) = Self.message(for: registration)
            outcome = Outcome(
                message: message, code: working ? nil : .agentNotReady, change: { $0.agentRegistration = registration })
        case .collectors:
            switch await work.collectorSources() {
            case .success(let sources):
                var message = String(localized: "\(sources.count) \(sources.count == 1 ? String(localized: "source") : String(localized: "sources")) checked")
                if let behind = HousekeepingStatus(sources: sources).behind { message += String(localized: ", \(behind.source) is behind") }
                outcome = Outcome(message: message, change: { $0.sources = sources })
            case .failure(let failure):
                // The last reading stands: a store that cannot be read right now says nothing new about the sources.
                outcome = Outcome(failure: failure)
            }
        }
        // The health keeps the words for Settings; the log gets the operation, the time and a code.
        log.log(LogRecord(.housekeeping, job.logOperation, outcome.code.map { .failed($0) } ?? .ok, millis: watch.millis))
        let now = clock.now()
        update {
            outcome.change(&$0)
            if outcome.ok {
                $0.jobs[job, default: JobHealth()].succeeded(at: now, message: outcome.message)
            } else {
                $0.jobs[job, default: JobHealth()].failed(at: now, message: outcome.message)
            }
        }
    }

    private func update(_ change: (inout HousekeepingStatus) -> Void) {
        let (next, notify) = lock.withLock { () -> (HousekeepingStatus, (@Sendable (HousekeepingStatus) -> Void)?) in
            change(&current)
            return (current, handler)
        }
        notify?(next)
    }

    // MARK: Words

    static func message(for outcome: BackupOutcome) -> String {
        let day = outcome.day ?? String(localized: "today")
        guard outcome.created else { return String(localized: "Today's backup, \(day), already exists") }
        var message = String(localized: "Backed up \(outcome.events ?? 0) \(outcome.events == 1 ? String(localized: "event") : String(localized: "events")) for \(day)")
        if outcome.pruned > 0 { message += String(localized: ", removed \(outcome.pruned) old \(outcome.pruned == 1 ? String(localized: "backup") : String(localized: "backups"))") }
        return message
    }

    static func message(for registration: AgentRegistration) -> (text: String, working: Bool) {
        switch registration {
        case .enabled: (String(localized: "The collector agent is registered"), true)
        case .requiresApproval: (String(localized: "Allow Cadence in System Settings, General, Login Items, so collectors can run"), false)
        case .notRegistered: (String(localized: "The collector agent is not registered"), false)
        case .notFound: (String(localized: "The collector agent is missing from the app"), false)
        }
    }
}

extension HousekeepingJob {
    var logOperation: LogOperation {
        switch self {
        case .spoolDrain: .jobSpoolDrain
        case .backup: .jobBackup
        case .agent: .jobAgent
        case .collectors: .jobCollectors
        }
    }
}
