import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// Every row of the failure table of docs/SPEC.md section 4.6, run for real against a store in a temporary folder
/// and through the app's own read and write paths: `DayStoreLoader` reads, `AppWriter` writes, `AppState` keeps what
/// did not land. For each row the test names the failure kind or source state the app reports, the words its card
/// carries, and what was not lost: the ledger as it was (count, head, chain, every projection), the text of a line
/// that did not land, and every file outside the store's own folder, so the app never reads or writes a second place.
///
/// Where the app falls short of the table, the test says what the table asks for inside `withKnownIssue`, so the gap
/// is on record and the test goes red the day it is closed. The notes at the head of each test say which.
@MainActor @Suite struct FaultInjectionTests {
    static let now = StoreRig.friday
    static let words = "Merged the retry budget change"

    /// The app as it starts: a model reading the rig's store and a writer of its own, which opens its connection on
    /// its first write.
    @MainActor struct Launch {
        let rig: StoreRig
        let clock: ManualClock
        let sink = AppLogTests.CapturingLog()
        let poster = AppWriterTests.CountingPoster()
        let app: AppState

        init(_ rig: StoreRig, at instant: Date = FaultInjectionTests.now) async {
            self.rig = rig
            clock = ManualClock(instant)
            let loader = DayStoreLoader(location: .found(rig.roots), clock: clock, log: sink)
            let writer = AppWriter(location: .found(rig.roots), clock: clock, poster: poster, log: sink)
            app = AppState(model: DayModel(loader: loader), writer: writer, clock: clock)
            await AppStateTests.settle(app)
        }

        var loader: DayStoreLoader { DayStoreLoader(location: .found(rig.roots), clock: clock) }

        /// The Today screen as the model now reads it.
        func today() -> TodayInput? { TodayInput(app: app) }

        /// Every log line says an operation, an outcome and a time, and nothing the person typed.
        func expectLogHoldsNoText(sourceLocation: SourceLocation = #_sourceLocation) {
            AppLogTests.expectClean(sink.messages, sourceLocation: sourceLocation)
            for message in sink.messages { #expect(!message.contains(FaultInjectionTests.words), sourceLocation: sourceLocation) }
        }

        func logged(_ operation: LogOperation, _ code: LogCode) -> Bool {
            sink.records.contains { $0.operation == operation && $0.outcome == .failed(code) }
        }
    }

    /// The app read and wrote nothing outside the store's own folder, and no screen holds a decoy's entry.
    static func expectOnlyThisStore(
        _ rig: StoreRig, outside before: [String: Data], _ launch: Launch, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(rig.outsideTheStore() == before, "a file outside the store changed or appeared", sourceLocation: sourceLocation)
        #expect(!before.isEmpty, sourceLocation: sourceLocation)
        #expect(!String(describing: launch.app.model.load).contains(StoreRig.decoyTitle), sourceLocation: sourceLocation)
        #expect(!String(describing: launch.app.unsavedText).contains(StoreRig.decoyTitle), sourceLocation: sourceLocation)
    }

    // MARK: Store busy past the 3 s timeout

    /// A second connection holds the write lock. The app's writer waits the full 3 s of its busy timeout (the writer
    /// has no shorter seam, so this test spends the real 3 s), then reports `.busy`; the line is kept for Copy my text
    /// and nothing reaches the ledger. A reader in WAL is not held up, so the day stays on screen: each surface fails
    /// alone. When the lock is gone, trying again lands the same line once.
    @Test func storeBusyPastTheTimeoutKeepsTheTextAndLosesNothing() async throws {
        let rig = StoreRig()
        defer { rig.remove() }
        try rig.seedDemo()
        let launch = await Launch(rig)
        let app = launch.app
        // The first write opens the writer's connection, as a running app has one.
        #expect(await app.log("Warmed up the writer") != nil)
        await AppStateTests.settle(app)

        let before = try rig.snapshot()
        let outside = rig.outsideTheStore()
        let holder = try rig.connection()
        try holder.execute("BEGIN IMMEDIATE")

        let started = ContinuousClock.now
        let landed = await app.log(Self.words)
        let waited = started.duration(to: .now)
        #expect(landed == nil)
        #expect(app.issue?.kind == .busy)
        #expect(waited >= .milliseconds(2900), "the writer gave up after \(waited), before the 3 s timeout")
        #expect(waited < .seconds(10))
        #expect(app.unsavedText == Self.words)
        #expect(launch.logged(.writeLog, .busy))
        // The banner for a write that did not land is built from the failure's own summary, not from the card.
        let summary = app.issue?.summary
        #expect(summary == FailureCopy(.busy).title)

        // The reader is not blocked by a writer in WAL, so Today still shows the day: only the write failed.
        await AppStateTests.settle(app)
        #expect(app.model.state != nil)
        #expect(launch.today()?.layout != .storeProblem(FailureCopy(.busy)))

        try holder.execute("ROLLBACK")
        #expect(try rig.snapshot() == before, "the ledger changed while the store was busy")
        #expect(try StoreRig.stored(rig.roots, title: Self.words) == 0)
        FailureTable.expect(FailureTable.busy)

        // Try again, with the lock gone: the kept line lands once, and the kept text and banner are cleared.
        #expect(await app.log(app.unsavedText ?? "") != nil)
        #expect(app.unsavedText == nil && app.issue == nil)
        #expect(try StoreRig.stored(rig.roots, title: Self.words) == 1)
        Self.expectOnlyThisStore(rig, outside: outside, launch)
        launch.expectLogHoldsNoText()
    }

    /// A holder in exclusive locking mode keeps readers out as well. The read path then reports `.busy` after its own
    /// 3 s and Today shows the busy card with its words, never an old day. Reading again after the holder lets go
    /// shows the day.
    @Test func aReaderKeptOutByAnExclusiveHolderShowsTheBusyCard() async throws {
        let rig = StoreRig()
        defer { rig.remove() }
        try rig.seedDemo()
        let launch = await Launch(rig)
        let app = launch.app
        #expect(app.model.state != nil)
        let before = try rig.snapshot()
        let outside = rig.outsideTheStore()

        let holder = try rig.connection()
        try holder.execute("PRAGMA locking_mode = EXCLUSIVE")
        try holder.execute("BEGIN EXCLUSIVE")
        try holder.execute("SELECT count(*) FROM events")

        // Off the main actor, as the model reads, so the 3 s wait does not hold up the other tests.
        let loader = launch.loader
        let started = ContinuousClock.now
        let load = await Task.detached { loader.load() }.value
        let waited = started.duration(to: .now)
        guard case .failed(let failure) = load else {
            Issue.record("the read went through an exclusive holder: \(load)")
            try holder.execute("ROLLBACK")
            return
        }
        #expect(failure.kind == .busy)
        #expect(waited >= .milliseconds(2900), "the read gave up after \(waited)")

        app.model.reload()
        await AppStateTests.settle(app)
        #expect(app.model.failure?.kind == .busy)
        #expect(app.state == nil, "a failed read must not leave an old day on screen")
        #expect(launch.today()?.layout == .storeProblem(FailureCopy(.busy)))
        #expect(launch.today()?.state == .storeProblem)
        FailureTable.expect(FailureTable.busy)

        try holder.execute("ROLLBACK")
        try holder.execute("PRAGMA locking_mode = NORMAL")
        try holder.execute("SELECT count(*) FROM events")
        app.model.reload()
        await AppStateTests.settle(app)
        #expect(app.model.state != nil)
        #expect(try rig.snapshot() == before)
        Self.expectOnlyThisStore(rig, outside: outside, launch)
    }

    // MARK: Schema newer than the app

    /// A newer Cadence has set `user_version` above what this build supports. Every write is refused before it can
    /// change anything: on the connection the writer already holds (checked under the write lock) and on a fresh one
    /// (the migrator refuses to open it). The app never lowers the version.
    ///
    /// Known gap: the table says the app will not read it either, but `DayStoreLoader` opens read-only and a read-only
    /// open accepts any version, so Today shows the day instead of the newer-schema card.
    @Test func aStoreFromANewerCadenceIsNeverWrittenAndTheLineIsKept() async throws {
        let rig = StoreRig()
        defer { rig.remove() }
        try rig.seedDemo()
        let launch = await Launch(rig)
        let app = launch.app
        #expect(await app.log("Warmed up the writer") != nil)
        await AppStateTests.settle(app)

        let newer = Schema.currentVersion + 1
        let editor = try rig.connection()
        try editor.setUserVersion(newer)
        let before = try rig.snapshot()
        let outside = rig.outsideTheStore()

        // The connection the writer already holds.
        #expect(await app.log(Self.words) == nil)
        #expect(app.issue?.kind == .newerSchema)
        #expect(app.unsavedText == Self.words)
        #expect(launch.logged(.writeLog, .newerSchema))

        // A writer that starts now, as after a relaunch.
        let fresh = await Launch(rig)
        #expect(await fresh.app.log(Self.words) == nil)
        #expect(fresh.app.issue?.kind == .newerSchema)
        #expect(fresh.app.unsavedText == Self.words)
        #expect(fresh.logged(.storeOpen, .newerSchema))
        let planned = await fresh.app.perform(.planAdd(title: "Plan the update", day: nil))
        #expect(planned == nil && fresh.app.issue?.kind == .newerSchema)

        #expect(try rig.snapshot() == before, "the ledger changed under a newer schema")
        #expect(try editor.userVersion() == newer, "the app changed the schema version")
        #expect(try StoreRig.stored(rig.roots, title: Self.words) == 0)
        FailureTable.expect(FailureTable.newerSchema)
        Self.expectOnlyThisStore(rig, outside: outside, launch)
        Self.expectOnlyThisStore(rig, outside: outside, fresh)

        // What the table asks of the read: the card, and no day.
        guard case .failed(let failure) = fresh.loader.load() else {
            Issue.record("the read of a newer schema loaded a day")
            return
        }
        #expect(failure.kind == .newerSchema)
    }

    // MARK: Sandbox denied or unreadable

    /// `cadence.db` itself cannot be read (mode 000), as a sandbox without the folder exception would leave it. The read
    /// and a writer that starts now both report `.denied`, Today shows the card with its words, the line is kept, the
    /// file is not touched and the app looks nowhere else.
    @Test func aDatabaseTheAppMayNotReadIsDeniedAndNothingIsChanged() async throws {
        try #require(geteuid() != 0, "permissions do not bind root")
        let rig = StoreRig()
        defer { rig.remove() }
        try rig.seedDemo()
        let before = try rig.snapshot()
        let bytes = try rig.databaseBytes()
        let outside = rig.outsideTheStore()
        let files = rig.roots.fileListing()

        #expect(chmod(rig.roots.database.path, 0o000) == 0)
        let launch = await Launch(rig)
        let app = launch.app
        guard case .failed(let failure) = launch.loader.load() else {
            Issue.record("an unreadable database loaded")
            return
        }
        #expect(failure.kind == .denied)
        #expect(app.model.failure?.kind == .denied)
        #expect(app.state == nil)
        #expect(launch.today()?.layout == .storeProblem(FailureCopy(.denied)))
        #expect(launch.today()?.state == .storeProblem)
        #expect(launch.logged(.dayLoad, .denied))

        #expect(await app.log(Self.words) == nil)
        #expect(app.issue?.kind == .denied)
        #expect(app.unsavedText == Self.words)
        #expect(launch.logged(.storeOpen, .denied))
        FailureTable.expect(FailureTable.denied)

        #expect(chmod(rig.roots.database.path, 0o600) == 0)
        #expect(try rig.databaseBytes() == bytes, "the database file was written")
        #expect(try rig.snapshot() == before)
        // The writer makes the folder skeleton (empty folders, mode 0700) before it opens the store; no file appears.
        #expect(rig.roots.fileListing() == files, "a file in the store's folder was made, changed or removed")
        Self.expectOnlyThisStore(rig, outside: outside, launch)
        launch.expectLogHoldsNoText()

        // Allowed again, trying again shows the day and the kept line lands once.
        app.model.reload()
        await AppStateTests.settle(app)
        #expect(app.model.state != nil)
        #expect(await app.log(app.unsavedText ?? "") != nil)
        #expect(app.unsavedText == nil)
        #expect(try StoreRig.stored(rig.roots, title: Self.words) == 1)
    }

    /// The whole folder is closed (mode 000), as when a sandbox denies the path. A writer that starts now reports
    /// `.denied` and keeps the line; nothing changes and nothing is made anywhere else.
    ///
    /// Known gap: the read cannot tell a closed folder from no folder, because it asks whether `cadence.db` exists, and
    /// that is false from outside a closed folder. It answers `.missing`, and Today shows the first-run welcome where
    /// the table asks for "Cadence cannot open its log".
    @Test func aFolderTheAppMayNotEnterIsDeniedForWritesAndNothingIsChanged() async throws {
        try #require(geteuid() != 0, "permissions do not bind root")
        let rig = StoreRig()
        defer { rig.remove() }
        try rig.seedDemo()
        let before = try rig.snapshot()
        let bytes = try rig.databaseBytes()
        let outside = rig.outsideTheStore()
        let files = rig.roots.fileListing()

        #expect(chmod(rig.roots.home.path, 0o000) == 0)
        let launch = await Launch(rig)
        let app = launch.app
        #expect(await app.log(Self.words) == nil)
        #expect(app.issue?.kind == .denied)
        #expect(app.unsavedText == Self.words)
        #expect(launch.logged(.storeOpen, .denied))
        FailureTable.expect(FailureTable.denied)
        #expect(chmod(rig.roots.home.path, 0o700) == 0, "the app changed the folder's mode while it was closed")
        #expect(chmod(rig.roots.home.path, 0o000) == 0)

        // What the table asks of the read.
        guard case .failed(let failure) = launch.loader.load() else {
            Issue.record("a closed folder loaded")
            return
        }
        #expect(failure.kind == .denied)
        #expect(launch.today()?.layout == .storeProblem(FailureCopy(.denied)))
        #expect(chmod(rig.roots.home.path, 0o700) == 0)

        #expect(try rig.databaseBytes() == bytes)
        #expect(try rig.snapshot() == before)
        #expect(rig.roots.fileListing() == files)
        Self.expectOnlyThisStore(rig, outside: outside, launch)
        launch.expectLogHoldsNoText()
    }

    /// A location the app could not work out at all fails both paths without touching the disk.
    @Test func aLocationThatCouldNotBeWorkedOutFailsEveryPathAndTouchesNothing() async throws {
        let rig = StoreRig()
        defer { rig.remove() }
        let outside = rig.outsideTheStore()
        let failed = StoreFailure(detail: "Cadence could not find your home folder")
        let clock = ManualClock(Self.now)
        let loader = DayStoreLoader(location: .failed(failed), clock: clock)
        #expect(loader.load() == .failed(failed))
        let app = AppState(
            model: DayModel(loader: loader), writer: AppWriter(location: .failed(failed), clock: clock, poster: AppWriterTests.CountingPoster()),
            clock: clock)
        await AppStateTests.settle(app)
        #expect(await app.log(Self.words) == nil)
        #expect(app.issue != nil && app.unsavedText == Self.words)
        #expect(rig.outsideTheStore() == outside)
        #expect(!FileManager.default.fileExists(atPath: rig.roots.home.path))
        #expect(!FileManager.default.fileExists(atPath: rig.roots.database.path))
    }

    // MARK: Missing is a first run

    /// No `cadence.db` at the place the app was told to use is a first run, never an error and never another place.
    /// Reading creates nothing. The first write makes the store there, and only there.
    @Test func aMissingStoreIsAFirstRunAndTheFirstWriteMakesItInPlace() async throws {
        let rig = StoreRig()
        defer { rig.remove() }
        let outside = rig.outsideTheStore()
        let launch = await Launch(rig)
        let app = launch.app
        #expect(app.model.failure?.kind == .missing)
        #expect(launch.today()?.layout == .firstRun)
        #expect(!FileManager.default.fileExists(atPath: rig.roots.home.path), "reading made the folder")

        #expect(await app.log(Self.words) != nil)
        await AppStateTests.settle(app)
        #expect(FileManager.default.fileExists(atPath: rig.roots.database.path))
        #expect(try StoreRig.stored(rig.roots, title: Self.words) == 1)
        #expect(app.model.state != nil)
        Self.expectOnlyThisStore(rig, outside: outside, launch)
    }

    // MARK: Corrupt

    enum Damage: String, CaseIterable, CustomTestStringConvertible {
        /// The file is not a database at all.
        case garbage
        /// The page of the entries table is overwritten; the header, the schema and the sidecars are as they were.
        case dataPage

        var testDescription: String { rawValue }
    }

    /// Garbage bytes in `cadence.db`. Both paths report `.corrupt`, Today shows the integrity card, the line is kept,
    /// and the file is byte for byte what it was: the app never repairs, truncates or recreates a file it cannot read.
    @Test(arguments: Damage.allCases)
    func aCorruptDatabaseIsReportedKeptAndNeverOverwritten(_ damage: Damage) async throws {
        let rig = StoreRig()
        defer { rig.remove() }
        try rig.seedDemo()
        let outside = rig.outsideTheStore()
        var bytes = try rig.databaseBytes()
        switch damage {
        case .garbage:
            bytes = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            try bytes.write(to: rig.roots.database)
        case .dataPage:
            let pageSize = 4096
            let connection = try rig.connection()
            let root = try #require(try connection.first("SELECT rootpage FROM sqlite_master WHERE name = 'entries'")?.int("rootpage"))
            #expect(try connection.first("PRAGMA page_size")?.int("page_size") == Int64(pageSize))
            try connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            let from = (Int(root) - 1) * pageSize
            for offset in from..<from + pageSize { bytes[offset] = 0xFF }
            let handle = try FileHandle(forWritingTo: rig.roots.database)
            try handle.seek(toOffset: UInt64(from))
            try handle.write(contentsOf: Data(repeating: 0xFF, count: pageSize))
            try handle.close()
        }

        let launch = await Launch(rig)
        let app = launch.app
        guard case .failed(let failure) = launch.loader.load() else {
            Issue.record("a corrupt database loaded (\(damage))")
            return
        }
        #expect(failure.kind == .corrupt, "\(failure)")
        #expect(app.model.failure?.kind == .corrupt)
        #expect(app.state == nil, "a failed read must not leave a day on screen")
        #expect(launch.today()?.layout == .storeProblem(FailureCopy(.corrupt)))
        #expect(launch.today()?.state == .storeProblem)
        #expect(launch.logged(.dayLoad, .corrupt))

        #expect(await app.log(Self.words) == nil)
        #expect(app.issue?.kind == .corrupt, "\(String(describing: app.issue))")
        #expect(app.unsavedText == Self.words)
        #expect(await app.writer.runBackup().failureKind == .corrupt)
        FailureTable.expect(FailureTable.corrupt)

        #expect(try rig.databaseBytes() == bytes, "the app wrote to a corrupt database")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: rig.roots.backups.path)) ?? []
        #expect(backups.isEmpty, "a backup of a corrupt file was kept: \(backups)")
        Self.expectOnlyThisStore(rig, outside: outside, launch)
        launch.expectLogHoldsNoText()
    }

    /// Found by this suite, outside the table: macOS's SQLite cannot open a WAL database read-only when no `-wal` and
    /// `-shm` lie beside it, though the folder is writable and the store is healthy. It answers "unable to open
    /// database file", which `DayStoreLoader` sorts as `.denied`, so Today shows "Cadence cannot open its log" until a
    /// read-write open (the CLI, or the app's first write) makes the sidecars. The same happens to a corrupt file in
    /// that state, which reads as denied instead of corrupt. The sidecars are absent after a backup is copied into
    /// place, or after anyone removes them.
    @Test func aHealthyStoreWithoutItsWALSidecarsIsReadable() async throws {
        let rig = StoreRig()
        defer { rig.remove() }
        try rig.seedDemo()
        for sidecar in ["-wal", "-shm"] { try FileManager.default.removeItem(atPath: rig.roots.database.path + sidecar) }
        let launch = await Launch(rig)
        guard case .loaded = launch.loader.load() else {
            Issue.record("a healthy store without sidecars did not load: \(launch.loader.load())")
            return
        }
        // Nothing was lost: a read-write open makes the sidecars and the same store reads.
        _ = try rig.connection()
        guard case .loaded = launch.loader.load() else {
            Issue.record("the store did not load after the sidecars were made")
            return
        }
        #expect(try rig.snapshot().chainOK)
    }

    enum ChainDamage: String, CaseIterable, CustomTestStringConvertible {
        /// One byte of one event's hash changed.
        case hashByte
        /// One event is gone from the middle of the ledger.
        case missingEvent

        var testDescription: String { rawValue }
    }

    /// A broken chain, made with raw SQL on the test's own copy (the append-only triggers are dropped there, as someone
    /// holding the file could). The chain verifier names it. The app's daily backup runs that verifier on the copy it
    /// makes, so `AppWriter.runBackup` is the app path that finds it: `.corrupt`, nothing kept under a backup's name,
    /// the ledger untouched.
    ///
    /// Known gap: the table says writing stops. Neither `DayStoreLoader` nor `AppWriter` walks the chain before a read
    /// or a write, so the day still loads and a line is still appended to the damaged ledger.
    @Test(arguments: ChainDamage.allCases)
    func aBrokenChainIsFoundByTheBackupAndNothingIsOverwritten(_ damage: ChainDamage) async throws {
        let rig = StoreRig()
        defer { rig.remove() }
        try rig.seedDemo()
        let editor = try rig.connection()
        let target: Int64 = 40
        switch damage {
        case .hashByte:
            try editor.execute("DROP TRIGGER events_no_update")
            let old = try #require(try editor.first("SELECT hash FROM events WHERE seq = ?", [.int(target)])?.text("hash"))
            let flipped = (old.first == "0" ? "1" : "0") + old.dropFirst()
            try editor.run("UPDATE events SET hash = ? WHERE seq = ?", [.text(flipped), .int(target)])
        case .missingEvent:
            try editor.execute("DROP TRIGGER events_no_delete")
            try editor.run("DELETE FROM events WHERE seq = ?", [.int(target)])
        }
        let before = try rig.snapshot()
        #expect(!before.chainOK, "the damage did not break the chain")
        let outside = rig.outsideTheStore()

        let launch = await Launch(rig)
        let app = launch.app
        // The read does not walk the chain.
        #expect(app.model.state != nil)

        let backup = await app.writer.runBackup()
        #expect(backup.failureKind == .corrupt, "\(backup)")
        #expect(launch.logged(.writeBackup, .corrupt))
        let names = try FileManager.default.contentsOfDirectory(atPath: rig.roots.backups.path)
        #expect(names.isEmpty, "a backup of a broken chain was kept: \(names)")
        #expect(try rig.snapshot() == before, "the ledger changed while the backup refused it")
        FailureTable.expect(FailureTable.corrupt)
        Self.expectOnlyThisStore(rig, outside: outside, launch)
        launch.expectLogHoldsNoText()

        // What the table asks of a write: refused as `.corrupt`.
        let result = await app.writer.perform(.log(LogRequest(text: Self.words)))
        guard case .failure(let failure) = result else {
            Issue.record("the write landed on a broken chain")
            return
        }
        #expect(failure.kind == .corrupt)
    }

    // MARK: A collector failing

    /// The GitHub built-in, run for real by the collector runner through the built `cadence` binary with `gh` pointing
    /// at `/usr/bin/false`, fails three times. After the first two it is not yet an error. After the third, the app's
    /// own reading of the ledger (`AppWriter.collectorSources`) says it is failing; that is one source that is
    /// behind, which turns the day's story, the mark and the panel's note, and which gives the one notice of the table,
    /// "GitHub has not synced for 3 hours", with Open Sources. Everything else keeps working: the day loads, a line lands, no issue.
    ///
    /// "Run it now" has no code behind it yet (Settings is a placeholder), so only Open Sources is checked.
    @Test func aCollectorFailingThreeTimesIsASourceBehindAndNothingElseStops() async throws {
        let rig = StoreRig()
        defer { rig.remove() }
        try rig.seedDemo()
        let binary = try CLIWriteLatencyTests.binary()
        var config = DemoSeed.config()
        config.collectors = [
            Config.Collector(
                name: "github", builtin: "github", env: ["CADENCE_HOME": rig.roots.home.path], gh: "/usr/bin/false", every: "3h")
        ]
        try ConfigStore.save(config, to: rig.roots.config)
        let outside = rig.outsideTheStore()

        // A good run three and a half hours ago, then three runs that fail.
        let clock = ManualClock(Self.now.addingTimeInterval(-3.5 * 3600))
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 31))
        let store = try SQLiteStore(path: rig.roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids, writesGenesis: false)
        let header =
            #"{"cadence":"envelope/1","collector":"github","run":"r1","generated_at":"2026-10-30T07:00:00+05:30","window":{"since":"2026-10-29","until":"2026-10-30"}}"# + "\n"
        let good = try journal.ingest(
            envelope: Array(header.utf8), collector: "github", window: IngestWindow(since: "2026-10-29", until: "2026-10-30"))
        #expect(good.status == "ok")
        let runner = CollectorRunner(
            roots: rig.roots, journal: journal, runner: SystemProcessRunner(), selfExecutable: binary.path,
            environment: ["HOME": rig.base.path, "LANG": "en_US.UTF-8"])
        try runner.approve(try CollectorRunner.plan(for: config.collectors[0], selfExecutable: binary.path))
        let boxed = RunnerBox(runner)
        clock.set(Self.now)

        let launch = await Launch(rig)
        let app = launch.app
        var housekeeping = HousekeepingStatus()
        for run in 1...3 {
            // The runner waits on a child process, so it runs off the main actor.
            let result = try await Task.detached { try boxed.run(window: IngestWindow(since: "2026-10-30", until: "2026-10-30")) }.value
            guard case .ran(let report) = result else {
                Issue.record("the runner refused run \(run): \(result)")
                return
            }
            #expect(report.status == "error", "run \(run): \(report.status), \(report.problems)")
            clock.advance(by: 60)
            let sources = try await app.writer.collectorSources().get()
            housekeeping.sources = sources
            let source = try #require(sources.first)
            #expect(source.failuresInARow == run)
            #expect(source.isFailing == (run == 3), "failing after \(run) failed runs")
            #expect(source.feedsCount)
            app.signals.behind = housekeeping.behind
            await AppStateTests.settle(app)
            #expect((app.story?.state == .sourceBehind) == (run == 3), "after \(run): \(String(describing: app.story?.state))")
        }

        // After the third: one source behind, in the words of the table.
        let behind = try #require(housekeeping.behind)
        #expect(behind.source == "GitHub" && behind.lastSync == "07:00")
        let source = try #require(housekeeping.sources.first)
        let lastGood = try #require(source.lastGoodRun)
        let hours = NotificationPlan.hoursBehind(since: lastGood, now: clock.now())
        #expect(hours == 3)
        let notice = try #require(NotificationPlan.sourceBehind(source: "GitHub", hours: hours))
        #expect(notice.title == "GitHub has not synced for 3 hours")
        #expect(notice.body == "Everything else keeps working.")
        #expect(notice.category == .source)
        #expect(NotificationAction.actions(for: .source) == [.openSources])
        #expect(NotificationAction.openSources.title == "Open Sources")
        #expect(NotificationPlan.reply(category: "SOURCE", response: .tap, day: nil) == .route(.sources))
        #expect(NotificationPlan.sourceBehind(source: "GitHub", hours: 2) == nil, "a notice before the threshold")

        let panel = PanelContent(PanelInput.from(app, pausedUntil: nil))
        #expect(panel.state == .sourceBehind)
        #expect(panel.note == PanelContent.Note(text: "GitHub last synced at 07:00.", button: .sources))
        #expect(MarkForm(state: .sourceBehind, level: 0, allResolved: false, discreet: false).ring?.kind == .broken)

        // Everything else keeps working.
        #expect(app.model.state != nil && app.issue == nil)
        #expect(await app.log(Self.words) != nil)
        await AppStateTests.settle(app)
        #expect(app.issue == nil && app.unsavedText == nil)
        #expect(app.context?.found.contains { $0.title == Self.words } == true)
        #expect(try rig.snapshot().chainOK)
        Self.expectOnlyThisStore(rig, outside: outside, launch)
    }

    // MARK: Notifications denied

    /// The pure path: a denial is a value of `NotificationAccess`, and nothing the day shows reads it. With the wrap-up
    /// due, the story, the mark's amber notch, the panel's action and Today's action are all there, and the plan of
    /// reminders is the same pure function of the day. (`CadenceApp` drops the system's pending requests when access is
    /// not allowed, which cannot be reached from here; and the card "Notifications are off", with Open System Settings
    /// and Not now, has no code behind it yet.)
    @Test func notificationsDeniedLeaveTheMarkAndEveryWrapUpSurfaceInPlace() async throws {
        let rig = StoreRig()
        defer { rig.remove() }
        try rig.seedDemo()
        let evening = Timestamp.parse("2026-10-30T17:45:00+05:30")!
        let launch = await Launch(rig, at: evening)
        let app = launch.app
        let task = await app.perform(.planAdd(title: "Review the ACME-101 change", day: nil))
        #expect(task != nil)
        await AppStateTests.settle(app)

        let denied = NotificationAccess.denied
        #expect(Set([NotificationAccess.notDetermined, .allowed, .denied]).count == 3)
        #expect(denied != .allowed)

        #expect(app.story?.state == .wrapUpDue)
        let form = MarkForm(state: .wrapUpDue, level: 0, allResolved: false, discreet: false)
        #expect(form.accent?.kind == .notch && form.accent?.hue == .amber && form.attention)
        let panel = PanelContent(PanelInput.from(app, pausedUntil: nil))
        #expect(panel.state == .wrapUpDue)
        #expect(panel.action == .wrapUp(open: 1))
        let today = try #require(TodayInput(app: app))
        #expect(today.actions.contains(.wrapUp))

        // The plan the app would hand the system is the same pure function of the day, whatever the system says.
        let config = DemoSeed.config()
        let zone = TimeZone(identifier: config.profile.timezone)!
        let input = NotificationInput(
            now: evening, zone: zone, rules: DayRules(config: config), reminders: config.reminders,
            facts: app.state.map { NotificationFacts(state: $0) })
        let plan = NotificationPlan.scheduled(input)
        #expect(plan.contains { $0.category == .wrap })
        #expect(NotificationPlan.scheduled(input) == plan)
        #expect(app.issue == nil)
    }
}

/// A collector runner used by one task at a time, so it may cross to a detached task.
final class RunnerBox: @unchecked Sendable {
    private let runner: CollectorRunner
    init(_ runner: CollectorRunner) { self.runner = runner }
    func run(window: IngestWindow) throws -> CollectorRunResult { try runner.run(name: "github", window: window) }
}

extension Result {
    /// The kind of a store failure, or nil on success.
    var failureKind: StoreFailure.Kind? {
        if case .failure(let error as StoreFailure) = self { return error.kind }
        return nil
    }
}

/// The disk-full row, at the layer below `AppWriter`. It runs off the main actor: it writes until the database is full,
/// which takes a couple of seconds, and the tests that need the main actor must not wait for it.
@Suite struct FaultInjectionDiskFullTests {
    static let now = StoreRig.friday

    /// The writer owns its connection and has no seam for `PRAGMA max_page_count`, which is a property of one
    /// connection and is not stored in the file, so a full disk cannot be made to reach `AppWriter` from a test (the
    /// other ways are a tiny disk image, which is not allowed, or a process-wide file size limit, which would fail
    /// every other test in the process). This test makes the real thing at the layer below it: a connection of the
    /// test's own with its page limit at the file's size, written through the same `Journal.log` the writer calls.
    /// SQLite answers SQLITE_FULL part way through a transaction; the write fails whole; the failure sorts to
    /// `.diskFull` by the same `StoreFailure` rule `AppWriter` applies; the card says what the table says; and the
    /// ledger, its chain and its projections are exactly as before, so the same line lands once when space returns.
    @Test func aFullDatabaseFailsWholeAndSortsAsDiskFull() throws {
        let rig = StoreRig()
        defer { rig.remove() }
        try rig.seedDemo()
        let outside = rig.outsideTheStore()
        let config = DemoSeed.config()
        let clock = ManualClock(Self.now)
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 21))
        let store = try SQLiteStore(path: rig.roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids, writesGenesis: false)
        let pages = try #require(try store.db.first("PRAGMA page_count")?.int("page_count"))
        try store.db.execute("PRAGMA max_page_count = \(pages)")

        var failure: CadenceError?
        var lines = 0
        var eventsBefore: Int64 = 0
        var headBefore: String?
        var lastTitle = ""
        while failure == nil && lines < 20_000 {
            eventsBefore = try store.eventCount()
            headBefore = try store.head()?.hash
            lastTitle = "Filled the log with line \(lines) of the day, a title long enough to need room"
            do {
                _ = try journal.log(LogRequest(text: lastTitle), actor: .app, origin: .selfReported)
                lines += 1
            } catch {
                failure = error
            }
        }
        let error = try #require(failure, "the database never filled")
        guard case .io(let message) = error else {
            Issue.record("a full database is an I/O error, got \(error)")
            return
        }
        #expect(message.contains("database or disk is full"), "\(message)")
        #expect(StoreFailure(error).kind == .diskFull)
        #expect(StoreFailure.kind(of: error) == .diskFull)
        FailureTable.expect(FailureTable.diskFull)

        // The failed write left nothing behind.
        #expect(try store.eventCount() == eventsBefore)
        #expect(try store.head()?.hash == headBefore)
        #expect(try store.verifyChain().ok)
        #expect(try StoreRig.stored(rig.roots, title: lastTitle) == 0)

        // Space returns: the projections agree with the ledger, and the same line lands once.
        try store.db.execute("PRAGMA max_page_count = 1073741823")
        let projected = try store.projectionDump()
        try store.rebuild()
        #expect(try store.projectionDump() == projected, "a failed write left a half-projected event")
        _ = try journal.log(LogRequest(text: lastTitle), actor: .app, origin: .selfReported)
        #expect(try StoreRig.stored(rig.roots, title: lastTitle) == 1)
        #expect(try store.eventCount() == eventsBefore + 1)
        #expect(try store.verifyChain().ok)
        #expect(rig.outsideTheStore() == outside)
    }
}
