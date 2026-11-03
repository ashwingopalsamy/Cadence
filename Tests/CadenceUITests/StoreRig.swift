import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// What a ledger holds, read on a connection of its own: the count, the head, whether the chain verifies and every
/// projection as canonical JSON lines. Two equal snapshots mean nothing was written or lost between them.
struct LedgerSnapshot: Equatable, CustomStringConvertible {
    var events: Int64
    var head: String?
    var chainOK: Bool
    var projections: String

    var description: String { "\(events) events, head \(head?.prefix(12) ?? "none"), chain \(chainOK ? "ok" : "broken")" }
}

/// A real store in a temporary folder for the fault, soak and budget suites (docs/SPEC.md sections 4.6 and 8). Nothing
/// here touches the real store: every path is below one folder made for the test, which `remove()` deletes, putting
/// permissions back first.
///
/// Beside the store sit decoy stores at the places an app could fall back to: the folder that holds the store, a
/// sibling, and a copy of `~/Library/Application Support/Cadence` below the base. Each holds one entry that no
/// screen may ever show. `outsideTheStore()` reads every file outside the store's own folder, so a test can prove the
/// app neither read a decoy into a screen nor wrote anywhere else.
final class StoreRig: @unchecked Sendable {
    /// The entry a decoy store holds. If a surface ever shows it, the app read the wrong place.
    static let decoyTitle = "DECOY entry that no screen may show"

    /// Friday 30 Oct 2026 10:30 in Kolkata, after the October demo's last sealed day.
    static let friday = Timestamp.parse("2026-10-30T10:30:00+05:30")!

    /// How many entries of the store carry this exact title.
    static func stored(_ roots: FileRoots, title: String) throws -> Int {
        let connection = try SQLiteDatabase(path: roots.database.path, readOnly: true)
        return Int(try connection.first("SELECT COUNT(*) AS n FROM entries WHERE title = ?", [.text(title)])?.int("n") ?? -1)
    }

    let base: URL
    let roots: FileRoots

    init(decoys: Bool = true) {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-rig-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        roots = FileRoots(home: base.appendingPathComponent("store", isDirectory: true))
        if decoys {
            for place in decoyHomes { Self.makeDecoy(at: place) }
        }
    }

    func remove() {
        // A folder a test made unreadable must be readable again before it can be deleted.
        chmodAll(base, folders: 0o700, files: 0o600)
        try? FileManager.default.removeItem(at: base)
    }

    private func chmodAll(_ folder: URL, folders: mode_t, files: mode_t) {
        chmod(folder.path, folders)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            let url = folder.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                chmodAll(url, folders: folders, files: files)
            } else if (info.st_mode & S_IFMT) == S_IFREG {
                chmod(url.path, files)
            }
        }
    }

    // MARK: Decoys

    /// The homes an app could wrongly fall back to.
    var decoyHomes: [FileRoots] {
        [
            FileRoots(home: base),
            FileRoots(home: base.appendingPathComponent("Cadence", isDirectory: true)),
            FileRoots(home: base.appendingPathComponent("Library/Application Support/Cadence", isDirectory: true)),
        ]
    }

    private static func makeDecoy(at roots: FileRoots) {
        try? FileManager.default.createDirectory(at: roots.home, withIntermediateDirectories: true)
        let config = Config.defaults(timezone: "Asia/Kolkata")
        try? ConfigStore.save(config, to: roots.config)
        let clock = ManualClock(Timestamp.parse("2026-10-30T10:00:00+05:30")!)
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 99))
        guard let store = try? SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector()),
            let journal = try? Journal(store: store, config: config, clock: clock, ids: ids)
        else { return }
        _ = try? journal.log(LogRequest(text: decoyTitle), actor: .cli, origin: .selfReported)
    }

    /// Every file below the base outside the store's own folder, by relative path, with its bytes. The decoys are small.
    func outsideTheStore() -> [String: Data] {
        var found: [String: Data] = [:]
        let store = roots.home.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return found }
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            if path == store || path.hasPrefix(store + "/") {
                walker.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, let data = try? Data(contentsOf: url) {
                found[String(path.dropFirst(base.standardizedFileURL.path.count))] = data
            }
        }
        return found
    }

    // MARK: Stores

    /// The October demo of ACME data in the rig's store, with the demo's own config.json. The demo is written once per
    /// test process through `Journal`, as the CLI writes it, and every rig gets a copy of those two files, so a test that
    /// damages its store damages only its own copy and the demo is not rebuilt on the main actor for each test.
    func seedDemo() throws {
        try FileManager.default.createDirectory(at: roots.home, withIntermediateDirectories: true)
        let template = FileRoots(home: try Self.demoTemplate())
        try FileManager.default.copyItem(at: template.database, to: roots.database)
        try FileManager.default.copyItem(at: template.config, to: roots.config)
        // A store that has been written has its `-wal` and `-shm` beside it, and macOS's SQLite keeps them when the last
        // connection closes. A read-only open cannot start without them (see `FaultInjectionTests`), so the copy gets what
        // every real store has: one read-write open, then closed.
        _ = try SQLiteDatabase(path: roots.database.path)
    }

    private static let template = Result { () throws -> URL in
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-demo-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("cadence-demo-\(getpid())")) }
        let roots = FileRoots(home: folder)
        let config = DemoSeed.config()
        try ConfigStore.save(config, to: roots.config)
        let clock = ManualClock(Timestamp.parse(DemoSeed.startInstant)!)
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1))
        let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids)
        try DemoSeed.seed(into: journal, clock: clock)
        // Everything in the one file, so a copy of it is the whole store.
        try store.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return folder
    }

    private static func demoTemplate() throws -> URL { try template.get() }

    // MARK: A year

    /// Twelve months of the year demo, written once per test process into a folder of its own with a cycle that starts on
    /// its first day, and removed when the process exits. Read it in place; `seedYear()` gives a rig a copy to write to.
    static let yearTemplate = Result { () throws -> FileRoots in
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-year-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("cadence-year-\(getpid())")) }
        let roots = FileRoots(home: folder)
        var config = DemoSeed.config()
        config.profile.backfillFrom = DemoSeed.yearFirstDay()
        try ConfigStore.save(config, to: roots.config)
        let clock = ManualClock(DemoSeed.yearStartInstant())
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1))
        let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids)
        try DemoSeed.year(into: journal, clock: clock)
        try store.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return roots
    }

    /// The year demo, shared and to be read only.
    static func year() throws -> FileRoots { try yearTemplate.get() }

    /// A copy of the year demo in this rig's store, with its sidecars, for a test that writes.
    func seedYear() throws {
        try FileManager.default.createDirectory(at: roots.home, withIntermediateDirectories: true)
        let template = try Self.year()
        try FileManager.default.copyItem(at: template.database, to: roots.database)
        try FileManager.default.copyItem(at: template.config, to: roots.config)
        _ = try SQLiteDatabase(path: roots.database.path)
    }

    /// Reads the ledger on a fresh read-only connection.
    func snapshot() throws -> LedgerSnapshot {
        try Self.snapshot(of: roots)
    }

    static func snapshot(of roots: FileRoots) throws -> LedgerSnapshot {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_790_000_000))
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 5))
        let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, readOnly: true)
        let report = try store.verifyChain()
        return LedgerSnapshot(
            events: try store.eventCount(), head: report.head, chainOK: report.ok, projections: try store.projectionDump())
    }

    /// The bytes of `cadence.db`, for the stores that cannot be opened.
    func databaseBytes() throws -> Data {
        try Data(contentsOf: roots.database)
    }

    /// A second connection on the store, for holding locks and for changes a test makes to its own copy.
    func connection() throws(SQLiteError) -> SQLiteDatabase {
        try SQLiteDatabase(path: roots.database.path)
    }
}

extension FileRoots {
    /// Every regular file below the home with its size, to show that a failed attempt wrote none. Empty folders are not
    /// listed: the writer makes the folder skeleton before it opens the store.
    func fileListing() -> [String] {
        guard let walker = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return []
        }
        var found: [String] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            found.append("\(url.path.dropFirst(home.path.count)) \(values.fileSize ?? -1)")
        }
        return found.sorted()
    }
}

/// The words of section 4.6, one row per kind a failure screen can show.
enum FailureTable {
    struct Row {
        var kind: StoreFailure.Kind
        var label: String
        var title: String
        var body: String
        var primary: String
        var secondary: String
    }

    static let busy = Row(
        kind: .busy, label: "Store busy past the 3 s timeout", title: "Your log is busy right now.", body: "Your text is kept.",
        primary: "Try again", secondary: "Copy my text")
    static let denied = Row(
        kind: .denied, label: "Sandbox denied or unreadable", title: "Cadence cannot open its log.",
        body: "Nothing has been changed, and it will not fall back to another location.", primary: "Show the folder",
        secondary: "Run cadence doctor")
    static let newerSchema = Row(
        kind: .newerSchema, label: "Schema newer than the app", title: "This log was updated by a newer Cadence.",
        body: "The app will not read or change it until you update.", primary: "See update steps", secondary: "Quit Cadence")
    static let diskFull = Row(
        kind: .diskFull, label: "Disk full", title: "Your Mac is out of space.", body: "The text is kept until you free some.",
        primary: "Try again", secondary: "Copy my text")
    static let corrupt = Row(
        kind: .corrupt, label: "Corrupt, missing or broken chain", title: "Your log did not pass its integrity check.",
        body: "Writing stopped; nothing is overwritten.", primary: "Restore from backup", secondary: "Show the damaged file")

    /// The card the app builds for `row.kind` says exactly what the table says.
    static func expect(_ row: Row, sourceLocation: SourceLocation = #_sourceLocation) {
        let copy = FailureCopy(row.kind)
        #expect(copy.label == row.label, sourceLocation: sourceLocation)
        #expect(copy.title == row.title, sourceLocation: sourceLocation)
        #expect(copy.body == row.body, sourceLocation: sourceLocation)
        #expect(copy.primary.title == row.primary, sourceLocation: sourceLocation)
        #expect(copy.secondary.title == row.secondary, sourceLocation: sourceLocation)
        #expect(CopyRules.allows(copy.title + " " + copy.body), sourceLocation: sourceLocation)
    }
}
