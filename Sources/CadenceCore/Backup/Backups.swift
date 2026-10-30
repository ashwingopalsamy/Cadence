import Foundation

/// A checked look at one backup file.
public struct BackupCheck: Sendable, Equatable {
    /// True when the file opens, `PRAGMA integrity_check` says ok and the hash chain verifies.
    public var ok: Bool { problems.isEmpty }
    public var events: Int64
    public var head: String?
    public var problems: [String]
}

/// One backup file in the backups folder. `check` is nil until the file has been verified.
public struct BackupFile: Sendable, Equatable {
    public var day: LocalDate
    public var url: URL
    public var bytes: Int64
    public var check: BackupCheck?
}

public struct BackupResult: Sendable, Equatable {
    /// False when today's backup already existed and nothing was written.
    public var created: Bool
    public var file: BackupFile?
    /// Events in the backup and its chain head (nil only when nothing was created and the file was not read).
    public var events: Int64?
    public var head: String?
    /// Files removed by retention during this run.
    public var pruned: [URL]
}

/// Daily snapshots of the store made with `VACUUM INTO` (docs/SPEC.md section 7.4), keeping 14 daily
/// and 8 weekly files.
///
/// Naming: `cadence-YYYY-MM-DD.db`, where the date is the profile-zone workday (the day boundary applies)
/// the backup was made for. Nothing else in the folder is ever deleted: only names that match exactly and
/// are real calendar dates, and only regular files (never links or folders). A backup is written under
/// `.cadence-YYYY-MM-DD.db.<uuid>.tmp`, verified, fsynced and renamed, so a crash leaves no half file under
/// a real name. Temporary files older than an hour are cleaned by `prune`.
///
/// Retention: the newest 14 files are the daily tier. Of the older files, the newest one in each Monday-to-Sunday
/// week is kept, for the 8 most recent such weeks. The live database is only read.
public struct Backups {
    public static let dailyKept = 14
    public static let weeklyKept = 8
    static let staleTemporarySeconds: TimeInterval = 3600

    public let store: SQLiteStore
    public let folder: URL
    public let clock: any Clock
    public let zone: TimeZone
    public let boundary: DayBoundary

    public init(store: SQLiteStore, folder: URL, clock: any Clock, zone: TimeZone, boundary: DayBoundary = .standard) {
        self.store = store
        self.folder = folder
        self.clock = clock
        self.zone = zone
        self.boundary = boundary
    }

    // MARK: Naming

    public static func fileName(for day: LocalDate) -> String { "cadence-\(day).db" }

    /// The day in a backup file name, or nil for any other name (including impossible dates).
    public static func day(fromFileName name: String) -> LocalDate? {
        guard name.hasPrefix("cadence-"), name.hasSuffix(".db"), name.utf8.count == "cadence-0000-00-00.db".utf8.count
        else { return nil }
        let text = String(name.dropFirst("cadence-".count).dropLast(".db".count))
        let bytes = Array(text.utf8)
        for (i, byte) in bytes.enumerated() {
            if i == 4 || i == 7 { guard byte == UInt8(ascii: "-") else { return nil } } else {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
            }
        }
        return LocalDate(text)
    }

    static func isTemporary(_ name: String) -> Bool {
        // .cadence-YYYY-MM-DD.db.<36 character uuid>.tmp
        guard name.hasPrefix(".cadence-"), name.hasSuffix(".tmp") else { return false }
        let middle = name.dropFirst(".".count).dropLast(".tmp".count)
        let parts = middle.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && day(fromFileName: String(parts[0]) + "." + String(parts[1])) != nil
            && parts[2].count == 36
    }

    public func url(for day: LocalDate) -> URL {
        folder.appendingPathComponent(Self.fileName(for: day))
    }

    // MARK: Running

    /// Today's workday as the backups see it.
    public func today() -> LocalDate { boundary.day(of: clock.now(), in: zone) }

    /// Makes today's backup unless one already exists. One cheap call for collectors and the app to repeat.
    @discardableResult
    public func runIfDue() throws(CadenceError) -> BackupResult { try run(force: false) }

    /// Makes a backup for the current workday. With `force` an existing one is replaced (atomically).
    /// Prunes afterwards. Throws `.storeBusy` if SQLite reports the store busy and `.integrity` if the
    /// new file fails verification, in which case nothing is left under a real name.
    @discardableResult
    public func run(force: Bool) throws(CadenceError) -> BackupResult {
        try prepareFolder()
        let day = today()
        let target = url(for: day)
        if !force, let existing = Self.describe(target) {
            return BackupResult(created: false, file: existing, events: nil, head: nil, pruned: [])
        }
        let before = try sourceHead()
        let temp = folder.appendingPathComponent(".\(Self.fileName(for: day)).\(UUID().uuidString).tmp")
        do {
            try store.db.vacuum(into: temp.path)
        } catch {
            unlink(temp.path)
            throw error.cadenceError
        }
        let check = examine(temp, expecting: before)
        guard check.ok else {
            unlink(temp.path)
            throw .integrity("backup for \(day) failed verification: \(check.problems.joined(separator: "; "))")
        }
        guard Self.sync(temp), rename(temp.path, target.path) == 0 else {
            unlink(temp.path)
            throw .io("cannot write \(target.lastPathComponent)")
        }
        let pruned = try prune()
        return BackupResult(
            created: true, file: Self.describe(target), events: check.events, head: check.head, pruned: pruned)
    }

    // MARK: Listing and verifying

    /// Every backup file, newest first. With `verify` each one is opened read-only and checked.
    public func list(verify: Bool = false) throws(CadenceError) -> [BackupFile] {
        var files = try entries()
        if verify {
            for i in files.indices { files[i].check = try self.verify(files[i]) }
        }
        return files
    }

    /// Opens the file read-only, runs `PRAGMA integrity_check` and walks the hash chain. Damage is
    /// reported in `problems`, not thrown.
    public func verify(_ file: BackupFile) throws(CadenceError) -> BackupCheck {
        examine(file.url, expecting: nil)
    }

    // MARK: Retention

    /// Applies retention and returns the files it deleted.
    @discardableResult
    public func prune() throws(CadenceError) -> [URL] {
        let files = try entries()
        var keep = Set<URL>(files.prefix(Self.dailyKept).map(\.url))
        var newestPerWeek: [(week: LocalDate, file: BackupFile)] = []
        for file in files.dropFirst(Self.dailyKept) {
            let week = Self.weekStart(file.day)
            if newestPerWeek.contains(where: { $0.week == week }) { continue }
            newestPerWeek.append((week, file))
        }
        for entry in newestPerWeek.sorted(by: { $0.week > $1.week }).prefix(Self.weeklyKept) { keep.insert(entry.file.url) }
        var removed: [URL] = []
        for file in files where !keep.contains(file.url) {
            if unlink(file.url.path) == 0 { removed.append(file.url) }
        }
        removeStaleTemporaries()
        return removed
    }

    // MARK: Internals

    static func weekStart(_ day: LocalDate) -> LocalDate {
        day.adding(days: -(Weekday.allCases.firstIndex(of: day.weekday) ?? 0))
    }

    private func prepareFolder() throws(CadenceError) {
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            throw .io("cannot prepare the backups folder")
        }
    }

    /// Backup files that match the naming scheme, newest first. Links and folders are ignored.
    private func entries() throws(CadenceError) -> [BackupFile] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            if !FileManager.default.fileExists(atPath: folder.path) { return [] }
            throw .io("cannot read the backups folder")
        }
        return names.compactMap { name in
            guard Self.day(fromFileName: name) != nil else { return nil }
            return Self.describe(folder.appendingPathComponent(name))
        }.sorted { $0.day > $1.day }
    }

    /// The file at `url` if it is a regular file with a backup name.
    static func describe(_ url: URL) -> BackupFile? {
        guard let day = day(fromFileName: url.lastPathComponent),
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return BackupFile(day: day, url: url, bytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0, check: nil)
    }

    private func sourceHead() throws(CadenceError) -> (seq: Int64, hash: String)? {
        do {
            guard let row = try store.db.first("SELECT seq, hash FROM events ORDER BY seq DESC LIMIT 1"),
                let seq = row.int("seq"), let hash = row.text("hash")
            else { return nil }
            return (seq, hash)
        } catch {
            throw error.cadenceError
        }
    }

    /// Opens `url` read-only and checks it. With `expecting` (the source head read before the copy was made)
    /// the backup must contain that event with that hash; a write that lands during the copy may add
    /// later events, which is fine.
    private func examine(_ url: URL, expecting: (seq: Int64, hash: String)?) -> BackupCheck {
        var check = BackupCheck(events: 0, head: nil, problems: [])
        do {
            let copy = try SQLiteStore(
                path: url.path, clock: store.clock, ids: store.ids, hashing: store.hashing, readOnly: true)
            let integrity = try copy.db.first("PRAGMA integrity_check")?.text("integrity_check") ?? "no result"
            if integrity != "ok" { check.problems.append("integrity_check: \(integrity)") }
            let report = try copy.verifyChain()
            check.events = report.events
            check.head = report.head
            check.problems += report.problems
            if let expecting {
                let row = try copy.db.first("SELECT hash FROM events WHERE seq = ?", [.int(expecting.seq)])
                if row?.text("hash") != expecting.hash { check.problems.append("does not contain the source chain head") }
            }
        } catch {
            check.problems.append("cannot be read: \(error)")
        }
        return check
    }

    private static func sync(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return fsync(fd) == 0
    }

    private func removeStaleTemporaries() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where Self.isTemporary(name) {
            let path = folder.appendingPathComponent(name).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let modified = attributes[.modificationDate] as? Date,
                clock.now().timeIntervalSince(modified) > Self.staleTemporarySeconds
            else { continue }
            unlink(path)
        }
    }
}
