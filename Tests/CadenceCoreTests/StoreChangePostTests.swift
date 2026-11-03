import Foundation
import Testing

@testable import CadenceCore

/// Writers post the store-changed notification after the commit, from the one commit point
/// (docs/SPEC.md section 8.2).
@Suite struct StoreChangePostTests {
    /// Counts posts, and records what a second connection could see at the moment of each one.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Int64] = []

        var posts: Int { lock.withLock { seen.count } }
        var rowsSeenAtPost: [Int64] { lock.withLock { seen } }

        func record(rows: Int64) { lock.withLock { seen.append(rows) } }
    }

    struct Boom: Error {}

    /// A read-only connection that the post closure may use: only that closure touches it, one commit at a time.
    final class Viewer: @unchecked Sendable {
        let db: SQLiteDatabase
        init(path: String) throws { db = try SQLiteDatabase(path: path, readOnly: true) }
        func rows() -> Int64 { (try? db.first("SELECT COUNT(*) AS n FROM t")?.int("n")) ?? -1 }
    }

    /// A database with a table, and a recorder that looks at the table through another connection when a post fires.
    static func fixture() throws -> (db: SQLiteDatabase, recorder: Recorder) {
        let path = SQLiteTests.tempPath()
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE t (i INTEGER)")
        let viewer = try Viewer(path: path)
        let recorder = Recorder()
        db.afterCommit = { recorder.record(rows: viewer.rows()) }
        return (db, recorder)
    }

    @Test func postsAfterTheCommitNotBefore() throws {
        let (db, recorder) = try Self.fixture()
        _ = try db.transaction(.immediate) {
            try db.run("INSERT INTO t VALUES (1)")
            try db.run("INSERT INTO t VALUES (2)")
            #expect(recorder.posts == 0)
        }
        #expect(recorder.posts == 1)
        // A second connection already saw both rows when the post fired: the commit was complete.
        #expect(recorder.rowsSeenAtPost == [2])
    }

    @Test func aRolledBackTransactionDoesNotPost() throws {
        let (db, recorder) = try Self.fixture()
        #expect(throws: Boom.self) {
            _ = try db.transaction(.immediate) {
                try db.run("INSERT INTO t VALUES (1)")
                throw Boom()
            }
        }
        #expect(recorder.posts == 0)
        // And the next real commit posts normally.
        _ = try db.transaction(.immediate) { try db.run("INSERT INTO t VALUES (2)") }
        #expect(recorder.rowsSeenAtPost == [1])
    }

    @Test func aTransactionSQLiteRolledBackItselfDoesNotPost() throws {
        let (db, recorder) = try Self.fixture()
        #expect(throws: SQLiteError.self) {
            _ = try db.transaction(.immediate) {
                try db.run("INSERT INTO t VALUES (1)")
                try db.execute("ROLLBACK")  // what a full disk or an interrupt does behind our back
            }
        }
        #expect(recorder.posts == 0)
    }

    @Test func nestedSavepointsPostOnceAtTheOuterCommit() throws {
        let (db, recorder) = try Self.fixture()
        _ = try db.transaction(.immediate) {
            _ = try db.transaction(.immediate) { try db.run("INSERT INTO t VALUES (1)") }
            _ = try? db.transaction(.immediate) { () throws -> Void in
                try db.run("INSERT INTO t VALUES (2)")
                throw Boom()
            }
            _ = try db.transaction(.immediate) { try db.run("INSERT INTO t VALUES (3)") }
            #expect(recorder.posts == 0)
        }
        #expect(recorder.posts == 1)
        #expect(recorder.rowsSeenAtPost == [2])
    }

    @Test func aFailedOuterTransactionPostsNothingEvenIfSavepointsReleased() throws {
        let (db, recorder) = try Self.fixture()
        #expect(throws: Boom.self) {
            _ = try db.transaction(.immediate) {
                _ = try db.transaction(.immediate) { try db.run("INSERT INTO t VALUES (1)") }
                throw Boom()
            }
        }
        #expect(recorder.posts == 0)
    }

    @Test func aReadNeverPostsSoAReloadCannotFeedItself() throws {
        let (db, recorder) = try Self.fixture()
        try db.run("INSERT INTO t VALUES (1)")
        let before = recorder.posts
        _ = try db.transaction(.deferred) { try db.query("SELECT * FROM t") }
        // An immediate transaction that finds nothing to write is a read too.
        _ = try db.transaction(.immediate) { try db.query("SELECT * FROM t") }
        #expect(recorder.posts == before)
    }

    @Test func eachCommitPostsOnce() throws {
        let (db, recorder) = try Self.fixture()
        for i in 1...3 { try db.transaction(.immediate) { try db.run("INSERT INTO t VALUES (?)", [.int(Int64(i))]) } }
        #expect(recorder.rowsSeenAtPost == [1, 2, 3])
    }

    // MARK: through the store

    @Test func theStorePostsOnceForAnAppendAndNothingForAFailedOne() throws {
        let store = try TestStore.make()
        let recorder = Recorder()
        store.db.afterCommit = { recorder.record(rows: 0) }
        try store.append([EventDraft(type: "ledger.genesis", subject: "ledger", data: ["created": "2026-09-21"], actor: .app)])
        #expect(recorder.posts == 1)
        #expect(throws: CadenceError.self) {
            try store.transact { () throws(CadenceError) -> Void in
                try store.append([EventDraft(type: "note.added", subject: "day:2026-09-21", data: [:], actor: .app)], then: { _ in })
                throw .validation("changed my mind")
            }
        }
        #expect(recorder.posts == 1)
        #expect(try store.eventCount() == 1)
        // Nothing to append is not a write.
        try store.append([])
        #expect(recorder.posts == 1)
    }

    @Test func aJournalWritePostsAfterItsCommitAndAReadDoesNot() throws {
        let clock = ManualClock(TestStore.start)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        let journal = try Journal(
            store: store, config: Config.defaults(timezone: "Asia/Kolkata"), clock: clock, ids: CountingIDs())
        let recorder = Recorder()
        store.db.afterCommit = { recorder.record(rows: 0) }
        _ = try journal.dayView(journal.today())
        _ = try journal.streak()
        #expect(recorder.posts == 0)
        _ = try journal.log(LogRequest(text: "reviewed a pull request"), actor: .cli, origin: .selfReported)
        #expect(recorder.posts == 1)
        _ = try journal.planAdd(title: "write the notes", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        #expect(recorder.posts == 2)
    }

    @Test func aWriterStorePostsButAMemoryOrReadOnlyStoreDoesNot() throws {
        let path = TestStore.tempDirectory("posts").appendingPathComponent("cadence.db").path
        #expect(try TestStore.make(path: path).db.afterCommit != nil)
        let readOnly = try SQLiteStore(path: path, clock: ManualClock(TestStore.start), ids: CountingIDs(), readOnly: true)
        #expect(readOnly.db.afterCommit == nil)
        let memory = try SQLiteStore(path: ":memory:", clock: ManualClock(TestStore.start), ids: CountingIDs())
        #expect(memory.db.afterCommit == nil)
    }

    @Test func theNotificationNameIsThePublishedContract() {
        // The app, the CLI and the agent must agree on this string; a build with another bundle prefix too.
        #expect(StoreChange.notificationName == "in.ashwingopalsamy.cadence.store-changed")
        // Posting with nobody listening, and on Linux with no notify center at all, is harmless.
        DarwinStoreChangePoster().postStoreChanged()
    }
}
