import Foundation
import Testing

@testable import CadenceCore

@Suite struct BackupTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!

    struct Fixture {
        let clock = ManualClock(TestStore.start)
        let store: SQLiteStore
        let databasePath: String
        let folder: URL
        let backups: Backups

        init() throws {
            databasePath = TestStore.tempDirectory().appendingPathComponent("cadence.db").path
            store = try TestStore.make(path: databasePath, clock: clock)
            try store.ensureGenesis(profile: ["name": "Sample Person"])
            folder = TestStore.tempDirectory().appendingPathComponent("backups", isDirectory: true)
            backups = Backups(store: store, folder: folder, clock: clock, zone: BackupTests.zone, boundary: .standard)
        }

        var names: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        }

        func mode(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
    }

    // MARK: Creating

    @Test func firstRunCreatesAVerifiedPrivateBackup() throws {
        let f = try Fixture()
        let result = try f.backups.runIfDue()
        #expect(result.created)
        let file = try #require(result.file)
        #expect(file.day.description == "2026-09-21")
        #expect(file.url.lastPathComponent == "cadence-2026-09-21.db")
        #expect(file.bytes > 0)
        #expect(result.events == 1)
        #expect(result.head == (try f.store.head()?.hash))
        #expect(try f.mode(file.url) == 0o600)
        #expect(try f.mode(f.folder) == 0o700)
        #expect(f.names == ["cadence-2026-09-21.db"])
        let check = try f.backups.verify(file)
        #expect(check.ok)
        #expect(check.events == 1)
    }

    @Test func atMostOneBackupPerWorkday() throws {
        let f = try Fixture()
        #expect(try f.backups.runIfDue().created)
        try f.store.append([LedgerTests.draft(1)])
        f.clock.advance(by: 3600)
        let again = try f.backups.runIfDue()
        #expect(!again.created)
        #expect(again.file?.url.lastPathComponent == "cadence-2026-09-21.db")
        #expect(f.names == ["cadence-2026-09-21.db"])
        // 03:30 the next morning is still the same workday (the boundary is 04:00).
        f.clock.set(Date(timeIntervalSince1970: 1_790_000_000 + 7 * 3600 + 30 * 60))
        #expect(Self.localHour(f.clock.now()) == 3)
        #expect(try !f.backups.runIfDue().created)
        // After 04:00 it is a new workday.
        f.clock.advance(by: 3600)
        let next = try f.backups.runIfDue()
        #expect(next.created)
        #expect(next.file?.day.description == "2026-09-22")
        #expect(next.events == 2)
    }

    @Test func forceReplacesTodaysBackupAtomically() throws {
        let f = try Fixture()
        _ = try f.backups.runIfDue()
        try f.store.append([LedgerTests.draft(1)])
        let forced = try f.backups.run(force: true)
        #expect(forced.created)
        #expect(forced.events == 2)
        #expect(f.names == ["cadence-2026-09-21.db"])
        #expect(try f.backups.verify(#require(forced.file)).events == 2)
    }

    @Test func leavesNoTemporaryFilesBehind() throws {
        let f = try Fixture()
        _ = try f.backups.runIfDue()
        #expect(f.names.allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") })
    }

    @Test func backupContainsTheWholeLedgerAndTheLiveStoreIsUntouched() throws {
        let f = try Fixture()
        for n in 1...25 { try f.store.append([LedgerTests.draft(n)]) }
        let before = try f.store.verifyChain()
        let result = try f.backups.runIfDue()
        #expect(result.events == 26)
        #expect(try f.store.verifyChain() == before)
        #expect(try f.store.eventCount() == 26)
    }

    @Test func succeedsWhileAnotherConnectionHoldsAWriteTransaction() throws {
        let f = try Fixture()
        let other = try SQLiteDatabase(path: f.databasePath, busyTimeoutMilliseconds: 50)
        try other.execute("BEGIN IMMEDIATE")
        try other.execute("CREATE TABLE IF NOT EXISTS scratch (x INTEGER)")
        defer { try? other.execute("ROLLBACK") }
        do {
            let result = try f.backups.runIfDue()
            #expect(result.created)
            #expect(try f.backups.verify(#require(result.file)).ok)
        } catch CadenceError.storeBusy {
            // Reporting busy clearly is the other acceptable outcome; nothing may be left behind.
            #expect(f.names.isEmpty)
        }
    }

    // MARK: Verification

    @Test func aTruncatedBackupIsFlagged() throws {
        let f = try Fixture()
        for n in 1...40 { try f.store.append([LedgerTests.draft(n)]) }
        let file = try #require(try f.backups.runIfDue().file)
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.truncate(atOffset: UInt64(file.bytes / 2))
        try handle.close()
        let check = try f.backups.verify(file)
        #expect(!check.ok)
        #expect(!check.problems.isEmpty)
        let listed = try f.backups.list(verify: true)
        #expect(listed.count == 1)
        #expect(listed[0].check?.ok == false)
    }

    @Test func aGarbageBackupIsFlagged() throws {
        let f = try Fixture()
        let file = try #require(try f.backups.runIfDue().file)
        try Data("not a database, ACME".utf8).write(to: file.url)
        #expect(try !f.backups.verify(file).ok)
    }

    @Test func listIsNewestFirstAndUnverifiedByDefault() throws {
        let f = try Fixture()
        for _ in 0..<3 {
            _ = try f.backups.runIfDue()
            f.clock.advance(by: 86_400)
        }
        let listed = try f.backups.list()
        #expect(listed.map { $0.day.description } == ["2026-09-23", "2026-09-22", "2026-09-21"])
        #expect(listed.allSatisfy { $0.check == nil })
        #expect(try f.backups.list(verify: true).allSatisfy { $0.check?.ok == true })
    }

    // MARK: Retention

    @Test func retentionOverAHundredAndTwentyDays() throws {
        let f = try Fixture()
        let first = LocalDate("2026-09-21")!
        for _ in 0..<120 {
            _ = try f.backups.runIfDue()
            f.clock.advance(by: 86_400)
        }
        let last = first.adding(days: 119)
        #expect(last.description == "2027-01-18")
        let kept = try f.backups.list().map(\.day)
        let daily = (0..<14).map { last.adding(days: -$0) }
        #expect(Array(kept.prefix(14)) == daily)
        #expect(kept.count == 22)
        // The weekly tier: for each of the 8 weeks before the daily window, the newest day in that week.
        let older = Array(kept.dropFirst(14))
        let expected = Self.expectedWeekly(all: LocalDate.range(first, through: last), dailyCutoff: last.adding(days: -13))
        #expect(older == expected)
        #expect(expected.count == 8)
        // Calendar check: the daily window starts on Tuesday 2027-01-05, so the newest weekly file is
        // Monday 2027-01-04, then the Sundays that close each earlier week, down to 2026-11-22.
        #expect(older.map(\.description) == [
            "2027-01-04", "2027-01-03", "2026-12-27", "2026-12-20", "2026-12-13", "2026-12-06", "2026-11-29",
            "2026-11-22",
        ])
        #expect(Set(older.map { Self.weekStart($0) }).count == 8)
    }

    @Test func fewerFilesThanTheLimitsAreAllKept() throws {
        let f = try Fixture()
        for _ in 0..<10 {
            _ = try f.backups.runIfDue()
            f.clock.advance(by: 86_400)
        }
        #expect(try f.backups.list().count == 10)
    }

    @Test func pruneReturnsWhatItDeleted() throws {
        let f = try Fixture()
        for _ in 0..<30 {
            _ = try f.backups.runIfDue()
            f.clock.advance(by: 86_400)
        }
        // The 30 days fill 14 daily and 3 weekly slots. Six older weeks make nine, so the oldest goes.
        var stale: URL?
        for week in 0..<6 {
            let day = LocalDate("2025-01-01")!.adding(days: 7 * week)
            let url = f.folder.appendingPathComponent("cadence-\(day).db")
            try Data("x".utf8).write(to: url)
            if week == 0 { stale = url }
        }
        let removed = try f.backups.prune()
        #expect(removed.map { $0.lastPathComponent } == ["cadence-2025-01-01.db"])
        #expect(!FileManager.default.fileExists(atPath: try #require(stale).path))
        #expect(try f.backups.list().count == 14 + 8)
    }

    @Test func strayFilesAreNeverTouched() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        let strays = [
            "notes.txt", "cadence-2026-13-45.db", "cadence-2026-01-01.db.bak", "other.db", "cadence-2026-1-1.db",
            "Cadence-2026-01-01.db", ".DS_Store", "cadence-2026-01-01.db-wal",
        ]
        for name in strays { try Data("keep".utf8).write(to: f.folder.appendingPathComponent(name)) }
        let directory = f.folder.appendingPathComponent("cadence-2026-01-02.db")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for _ in 0..<80 {
            _ = try f.backups.runIfDue()
            f.clock.advance(by: 86_400)
        }
        for name in strays {
            #expect(FileManager.default.fileExists(atPath: f.folder.appendingPathComponent(name).path), "\(name)")
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try f.backups.list().count == 22)
    }

    @Test func staleTemporaryFilesFromACrashAreCleanedAfterAnHour() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        let temp = f.folder.appendingPathComponent(".cadence-2026-09-20.db.\(UUID().uuidString).tmp")
        try Data("half".utf8).write(to: temp)
        try FileManager.default.setAttributes([.modificationDate: f.clock.now().addingTimeInterval(-7200)], ofItemAtPath: temp.path)
        let fresh = f.folder.appendingPathComponent(".cadence-2026-09-21.db.\(UUID().uuidString).tmp")
        try Data("busy".utf8).write(to: fresh)
        _ = try f.backups.runIfDue()
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    // MARK: Helpers

    static func localHour(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.component(.hour, from: date)
    }

    static func weekStart(_ date: LocalDate) -> LocalDate {
        date.adding(days: -(Weekday.allCases.firstIndex(of: date.weekday) ?? 0))
    }

    /// Independent restatement of the rule: older than the daily window, newest per week, 8 most recent weeks.
    static func expectedWeekly(all: [LocalDate], dailyCutoff: LocalDate) -> [LocalDate] {
        var newest: [LocalDate: LocalDate] = [:]
        for day in all where day < dailyCutoff {
            let week = weekStart(day)
            if let existing = newest[week], existing >= day { continue }
            newest[week] = day
        }
        return newest.keys.sorted(by: >).prefix(8).compactMap { newest[$0] }
    }
}
