import CadenceCore
import Foundation

/// Everything the app writes (docs/SPEC.md section 8.2). There is no other write path in the app.
public enum WriteAction: Sendable {
    case log(LogRequest)
    case planAdd(title: String, day: LocalDate?)
    case planCommit(day: LocalDate?, tasks: [String], focus: String?)
    case resolve(task: String, status: TaskStatus, reason: String?)
    /// Move to tomorrow: slipped here with its reason, carried to the next workday.
    case move(task: String, reason: String)
    case seal(day: LocalDate?)
    case declare(day: LocalDate, kind: DayKind, label: String?)
    case setStatus(entry: String, status: EntryStatus)
    /// A new title, kind or list of links for an entry; the history keeps the old one.
    case editEntry(entry: String, title: String?, kind: EntryKind?, links: [Link]? = nil)
    case standup(day: LocalDate?)
}

/// What a write gave back, when it gave back something the surface shows.
public enum WriteResult: Sendable, Equatable {
    case none
    case entry(Entry)
    case task(PlanTask)
    case sealed(SealResult)
    case standup(text: String, code: String)
}

/// The app's only writer: one actor with its own connection. Every action returns success or a specific failure,
/// and the caller reloads at once, so a surface never shows something the ledger refused.
///
/// Every call is logged with its timing and, on failure, a fixed error code, never the text it carried (section 13).
public actor AppWriter {
    private let location: StoreLocation
    private let clock: any Clock
    private let poster: any StoreChangePoster
    private let log: any AppLogSink
    private var journal: Journal?
    /// The config file as it was when the journal was made; a change (a new zone, a new boundary) remakes the journal.
    private var configStamp: [FileAttributeKey: AnyHashable]?
    private var roots: FileRoots?
    /// The presence machine between events. Loaded from `state/` on the first one, so a restart carries on from it.
    private var presence: PresenceMachine?
    private var presenceLoaded = false

    public init(
        location: StoreLocation, clock: any Clock, poster: any StoreChangePoster = DarwinStoreChangePoster(),
        log: any AppLogSink = AppLog.system
    ) {
        self.location = location
        self.clock = clock
        self.poster = poster
        self.log = log
    }

    public func perform(_ action: WriteAction) -> Result<WriteResult, StoreFailure> {
        withJournal(.writer, action.logOperation) { (journal, _) throws(CadenceError) -> WriteResult in
            let result = try Self.run(action, on: journal)
            // The CLI, the MCP server and other windows hear about it as they hear about any other writer.
            poster.postStoreChanged()
            return result
        }
    }

    /// One presence event, as the app: the machine runs at `instant`, what it asks for is written in one transaction,
    /// and the machine is saved after the event, where a restart finds it. A write that fails leaves the machine as it
    /// was, so the same event can be sent again with the same `instant`.
    public func recordPresence(_ event: PresenceEvent, at instant: Date) -> Result<PresenceWrite, StoreFailure> {
        var isSample = false
        if case .sample = event { isSample = true }
        return withJournal(.presence, isSample ? .presenceSample : .presenceEvent) { (journal, roots) throws(CadenceError) -> PresenceWrite in
            let file = PresenceStateFile(roots: roots)
            if !presenceLoaded {
                // An unreadable file starts a fresh machine: losing one open span is better than refusing every event.
                if case .machine(let saved) = file.load() { presence = saved }
                presenceLoaded = true
            }
            let engine = PresenceEngine(journal: journal, clock: clock, restoring: presence)
            let written = try engine.handle(event, at: instant)
            presence = engine.machine
            // A save that fails costs only the crash recovery of the next minute; the event itself is written.
            do throws(CadenceError) {
                try file.save(engine.machine)
            } catch {
                log.log(LogRecord(.presence, .presenceSave, .failed(LogCode(StoreFailure.kind(of: error))), millis: 0))
            }
            if written != .none { poster.postStoreChanged() }
            return written
        }
    }

    // MARK: Housekeeping (section 8.1): the same connection, so the app never has a second writer

    /// Turns the hook spool into `genai.session` events. Announces a change only when it wrote rows.
    public func drainSpool() -> Result<DrainReport, StoreFailure> {
        withJournal(.writer, .writeSpoolDrain) { (journal, roots) throws(CadenceError) -> DrainReport in
            let report = try SpoolDrain(
                roots: roots, store: journal.store, config: journal.config, clock: clock, genesisActor: .app
            ).drain()
            if report.eventsWritten > 0 { poster.postStoreChanged() }
            return report
        }
    }

    /// Today's backup unless it exists, then retention. Retention runs either way, so a folder that grew while the
    /// app was off is trimmed on the next check.
    public func runBackup() -> Result<BackupOutcome, StoreFailure> {
        withJournal(.writer, .writeBackup) { (journal, roots) throws(CadenceError) -> BackupOutcome in
            let backups = Backups(
                store: journal.store, folder: roots.backups, clock: clock, zone: journal.zone,
                boundary: journal.config.dayBoundary)
            let result = try backups.runIfDue()
            let pruned = result.created ? result.pruned.count : try backups.prune().count
            return BackupOutcome(created: result.created, day: result.file?.day.description, events: result.events, pruned: pruned)
        }
    }

    /// Each enabled collector in the config as it is now: its failures in a row and its last good run, read from the
    /// ledger's `ingest.run` events. The config is read afresh, so a collector added while the app runs shows up.
    public func collectorSources() -> Result<[CollectorSource], StoreFailure> {
        withJournal(.writer, .writeCollectors) { (journal, roots) throws(CadenceError) -> [CollectorSource] in
            let config = try ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0
            let zone = TimeZone(identifier: config.profile.timezone) ?? journal.zone
            let now = clock.now()
            var sources: [CollectorSource] = []
            for collector in config.collectors where collector.enabled {
                let health = try CollectorRunner.health(name: collector.name, store: journal.store)
                let (lastGood, produced) = try Self.collectorFacts(collector.name, store: journal.store)
                sources.append(
                    CollectorSource.make(
                        collector: collector, failuresInARow: health.failuresInARow, lastError: health.lastError,
                        lastGoodRun: lastGood, producedItems: produced, now: now, zone: zone))
            }
            return sources
        }
    }

    /// The time of a collector's last good run, and whether it has written an accepted item the day counts.
    private static func collectorFacts(_ name: String, store: SQLiteStore) throws(CadenceError) -> (Date?, Bool) {
        do {
            let run = try store.db.first(
                """
                SELECT at FROM events
                WHERE type = 'ingest.run' AND actor = ? AND json_extract(data, '$.status') = 'ok'
                ORDER BY seq DESC LIMIT 1
                """, [.text(Actor.collector(name).rawValue)])
            let item = try store.db.first(
                """
                SELECT 1 AS found FROM entries
                WHERE source = ? AND origin = 'collected' AND status = 'accepted' AND family NOT IN ('ai', 'presence')
                LIMIT 1
                """, [.text(name)])
            return (run?.text("at").flatMap(Timestamp.parse), item != nil)
        } catch {
            throw error.cadenceError
        }
    }

    /// Opens the store if it is not open and runs `body` on it, as a result and with one log line: the operation, its
    /// time and, on failure, the failure's kind. A store that cannot be opened is a failure of its own kind; a
    /// refusal by the ledger is the owner's to fix, and a failed connection is opened afresh next time, so a store
    /// fixed meanwhile is picked up.
    private func withJournal<Value>(
        _ category: LogCategory, _ operation: LogOperation, _ body: (Journal, FileRoots) throws(CadenceError) -> Value
    ) -> Result<Value, StoreFailure> {
        let watch = Stopwatch()
        let result: Result<Value, StoreFailure>
        do throws(CadenceError) {
            let journal = try open()
            guard let roots else { throw .io(String(localized: "Cadence could not find its store")) }
            do throws(CadenceError) {
                result = .success(try body(journal, roots))
            } catch {
                result = .failure(failure(error))
            }
        } catch {
            result = .failure(Self.tabled(StoreFailure(error)))
        }
        log.log(category, operation, result, since: watch)
        return result
    }

    /// A store failure says what the failure table of section 4.6 says for its kind, so the banner and the card agree.
    static func tabled(_ failure: StoreFailure) -> StoreFailure {
        var tabled = failure
        tabled.summary = FailureCopy(failure.kind).title
        return tabled
    }

    private func failure(_ error: CadenceError) -> StoreFailure {
        switch error {
        case .validation, .notFound, .usage:
            return StoreFailure(kind: .invalid, summary: String(localized: "Cadence could not do that"), detail: error.message)
        default:
            if case .io = error { journal = nil }
            return Self.tabled(StoreFailure(error))
        }
    }

    static func run(_ action: WriteAction, on journal: Journal) throws(CadenceError) -> WriteResult {
        switch action {
        case .log(let request):
            return .entry(try journal.log(request, actor: .app, origin: .selfReported))
        case .planAdd(let title, let day):
            return .task(try journal.planAdd(title: title, day: day, estimateMin: nil, origin: .selfReported, actor: .app))
        case .planCommit(let day, let tasks, let focus):
            try journal.planCommit(day: day, tasks: tasks, focus: focus, actor: .app)
            return .none
        case .resolve(let task, let status, let reason):
            return .task(try journal.planResolve(taskID: task, status: status, reason: reason, note: nil, links: [], actor: .app))
        case .move(let task, let reason):
            return .task(try journal.planMove(taskID: task, reason: reason, actor: .app).task)
        case .seal(let day):
            return .sealed(try journal.seal(day, actor: .app))
        case .declare(let day, let kind, let label):
            try journal.declare(day, kind: kind, label: label, actor: .app)
            return .none
        case .editEntry(let entry, let title, let kind, let links):
            return .entry(try journal.entryEdit(entryID: entry, title: title, kind: kind, links: links, actor: .app))
        case .setStatus(let entry, let status):
            return .entry(try journal.setStatus(entryID: entry, to: status, note: nil, actor: .app))
        case .standup(let day):
            let standup = try journal.standup(day, actor: .app)
            return .standup(text: standup.text, code: standup.code)
        }
    }

    /// Opens the store for writing once and keeps the connection. The app may create the store on a first run, in
    /// the one place it was told to use; it never falls back to another.
    private func open() throws(CadenceError) -> Journal {
        if let journal, let roots, configStamp == Self.stamp(roots.config) { return journal }
        if let journal, let roots {
            // The config changed since the journal was made: the same connection, the profile as it is now, so a zone
            // change takes effect at once, as it does for the reader and the CLI.
            let config = try ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0
            let remade = try Journal(
                store: journal.store, config: config, clock: clock, ids: ULIDGenerator(clock: clock, random: SystemRandomSource()),
                actor: .app)
            self.journal = remade
            configStamp = Self.stamp(roots.config)
            return remade
        }
        let roots: FileRoots
        switch location {
        case .found(let found): roots = found
        case .failed(let failure): throw .io(failure.detail)
        }
        self.roots = roots
        let watch = Stopwatch()
        do {
            let opened = try openFresh(roots)
            journal = opened
            configStamp = Self.stamp(roots.config)
            log.log(LogRecord(.store, .storeOpen, .ok, millis: watch.millis))
            return opened
        } catch {
            log.log(LogRecord(.store, .storeOpen, .failed(LogCode(StoreFailure.kind(of: error))), millis: watch.millis))
            throw error
        }
    }

    private func openFresh(_ roots: FileRoots) throws(CadenceError) -> Journal {
        for folder in roots.folders {
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw .io(String(localized: "could not create \(folder.path): permission denied or \(error.localizedDescription)"))
            }
        }
        let config = try ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0
        let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
        let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
        // A ledger whose chain does not verify is never written to (section 4.6): writing stops, nothing is
        // overwritten, and restore from a backup is offered.
        let chain = try store.verifyChain()
        guard chain.ok else { throw .integrity(chain.problems.first ?? "the ledger's chain does not verify") }
        return try Journal(store: store, config: config, clock: clock, ids: ids, actor: .app)
    }

    /// When and how big the config file is, enough to notice that it changed.
    private static func stamp(_ url: URL) -> [FileAttributeKey: AnyHashable]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        var stamp: [FileAttributeKey: AnyHashable] = [:]
        if let date = attributes[.modificationDate] as? Date { stamp[.modificationDate] = date }
        if let size = attributes[.size] as? NSNumber { stamp[.size] = size.intValue }
        return stamp
    }
}

extension WriteAction {
    /// The fixed word for this action in the log. Never its arguments.
    var logOperation: LogOperation {
        switch self {
        case .log: .writeLog
        case .planAdd: .writePlanAdd
        case .planCommit: .writePlanCommit
        case .resolve, .move: .writeResolve
        case .seal: .writeSeal
        case .declare: .writeDeclare
        case .setStatus, .editEntry: .writeSetStatus
        case .standup: .writeStandup
        }
    }
}
