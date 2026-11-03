import Foundation
import Testing

@testable import CadenceCore

@Suite struct SQLiteTests {
    static func tempPath() -> String {
        let dir = TestStore.tempDirectory("sqlite")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.db").path
    }

    @Test func opensInWALWithPrivateMode() throws {
        let path = Self.tempPath()
        let db = try SQLiteDatabase(path: path)
        #expect(try db.first("PRAGMA journal_mode")?.text("journal_mode") == "wal")
        #expect(try db.first("PRAGMA foreign_keys")?.int("foreign_keys") == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func typedRowsRoundTrip() throws {
        let db = try SQLiteDatabase(path: Self.tempPath())
        try db.execute("CREATE TABLE t (i INTEGER, s TEXT, b BLOB, n TEXT)")
        try db.run("INSERT INTO t VALUES (?, ?, ?, ?)", [.int(9_007_199_254_740_991), .text("São Paulo · ₹"), .blob([0, 1, 255]), .null])
        let row = try #require(try db.first("SELECT * FROM t"))
        #expect(row.int("i") == 9_007_199_254_740_991)
        #expect(row.text("s") == "São Paulo · ₹")
        #expect(row["b"] == .blob([0, 1, 255]))
        #expect(row["n"] == .null)
        #expect(row["missing"] == .null)
    }

    @Test func transactionsCommitAndRollBack() throws {
        let db = try SQLiteDatabase(path: Self.tempPath())
        try db.execute("CREATE TABLE t (i INTEGER)")
        _ = try db.transaction(.immediate) { try db.run("INSERT INTO t VALUES (1)") }
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.transaction(.immediate) {
                try db.run("INSERT INTO t VALUES (2)")
                throw Boom()
            }
        }
        #expect(try db.query("SELECT i FROM t").count == 1)
        // Nested transactions join through savepoints; an inner failure rolls back only the inner part.
        try db.transaction {
            try db.run("INSERT INTO t VALUES (3)")
            _ = try? db.transaction { () throws -> Void in
                try db.run("INSERT INTO t VALUES (4)")
                throw Boom()
            }
        }
        #expect(try db.query("SELECT i FROM t ORDER BY i").compactMap { $0.int("i") } == [1, 3])
    }

    @Test func userVersion() throws {
        let db = try SQLiteDatabase(path: Self.tempPath())
        #expect(try db.userVersion() == 0)
        try db.setUserVersion(3)
        #expect(try db.userVersion() == 3)
    }

    @Test func busyWriterMapsToStoreBusy() throws {
        let path = Self.tempPath()
        let a = try SQLiteDatabase(path: path, busyTimeoutMilliseconds: 50)
        let b = try SQLiteDatabase(path: path, busyTimeoutMilliseconds: 50)
        try a.execute("CREATE TABLE t (i INTEGER)")
        try a.execute("BEGIN IMMEDIATE")
        do {
            try b.execute("BEGIN IMMEDIATE")
            Issue.record("second writer should be busy")
        } catch {
            #expect(error.isBusy)
            #expect(error.cadenceError == .storeBusy)
        }
        try a.execute("COMMIT")
    }

    @Test func dataVersionChangesOnOtherConnectionsCommit() throws {
        let path = Self.tempPath()
        let a = try SQLiteDatabase(path: path)
        let b = try SQLiteDatabase(path: path)
        try a.execute("CREATE TABLE t (i INTEGER)")
        let before = try b.dataVersion()
        try a.run("INSERT INTO t VALUES (1)")
        #expect(try b.dataVersion() != before)
    }

    @Test func readOnlyRefusesWrites() throws {
        let path = Self.tempPath()
        let rw = try SQLiteDatabase(path: path)
        try rw.execute("CREATE TABLE t (i INTEGER)")
        let ro = try SQLiteDatabase(path: path, readOnly: true)
        #expect(throws: SQLiteError.self) { try ro.run("INSERT INTO t VALUES (1)") }
    }

    @Test func parameterCountIsChecked() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        #expect(throws: SQLiteError.self) { try db.run("SELECT ?", []) }
    }

    @Test func realValuesAreRefused() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        #expect(throws: SQLiteError.self) { _ = try db.query("SELECT 1.5 AS x") }
    }

    @Test func vacuumIntoMakesACopy() throws {
        let path = Self.tempPath()
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE t (i INTEGER); INSERT INTO t VALUES (7);")
        let copy = path + ".bak"
        try db.vacuum(into: copy)
        let restored = try SQLiteDatabase(path: copy, readOnly: true)
        #expect(try restored.first("SELECT i FROM t")?.int("i") == 7)
    }
}
