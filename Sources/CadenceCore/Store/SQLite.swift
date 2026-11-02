#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import Foundation

/// A value bound to or read from SQLite. Cadence stores no REAL values.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case text(String)
    case blob([UInt8])
}

extension SQLValue: ExpressibleByNilLiteral, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(stringLiteral value: String) { self = .text(value) }

    public init(_ value: String?) { self = value.map(SQLValue.text) ?? .null }
    public init(_ value: Int64?) { self = value.map(SQLValue.int) ?? .null }
    public init(_ value: Int?) { self = value.map { SQLValue.int(Int64($0)) } ?? .null }
    public init(_ value: Bool) { self = .int(value ? 1 : 0) }
}

/// A failure reported by SQLite, with its primary result code.
public struct SQLiteError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var isBusy: Bool { code == SQLITE_BUSY || code == SQLITE_LOCKED }
    public var isConstraint: Bool { code == SQLITE_CONSTRAINT }
    public var description: String { "sqlite error \(code): \(message)" }

    /// The CadenceError a caller sees: busy maps to exit code 3, everything else is I/O.
    public var cadenceError: CadenceError {
        isBusy ? .storeBusy : .io(description)
    }
}

/// One row of a result, addressable by column name or index.
public struct SQLRow: Sendable, Equatable {
    public let columns: [String]
    public let values: [SQLValue]

    public subscript(_ name: String) -> SQLValue {
        guard let index = columns.firstIndex(of: name) else { return .null }
        return values[index]
    }

    public func int(_ name: String) -> Int64? {
        if case .int(let i) = self[name] { return i }
        return nil
    }

    public func text(_ name: String) -> String? {
        if case .text(let s) = self[name] { return s }
        return nil
    }

    public func bool(_ name: String) -> Bool { int(name).map { $0 != 0 } ?? false }
}

/// A thin, typed wrapper over one SQLite connection (docs/SPEC.md section 7.3).
///
/// Opens in WAL mode with `foreign_keys` on and a busy timeout, creates the file with mode 0600,
/// and exposes statements, transactions and `user_version`. Not shared across threads: each
/// process or task opens its own connection, and SQLite serialises writers.
public final class SQLiteDatabase {
    public enum TransactionKind: String, Sendable {
        case deferred = "DEFERRED"
        case immediate = "IMMEDIATE"
    }

    public let path: String
    public let readOnly: Bool
    private var handle: OpaquePointer?
    private var transactionDepth = 0
    private var outerKind: TransactionKind = .deferred

    /// Runs once after an outermost transaction that changed rows has committed, and never for a rollback,
    /// a failed commit, a nested savepoint or a read. It is the single commit point of the store, so the
    /// store-changed notification (docs/SPEC.md section 8.2) is posted from here and nowhere else. It runs
    /// after the write lock is released, so a listener woken by it can read at once.
    public var afterCommit: (@Sendable () -> Void)?

    /// Opens (and for read-write, creates) the database at `path`.
    public init(path: String, readOnly: Bool = false, busyTimeoutMilliseconds: Int32 = 3000) throws(SQLiteError) {
        self.path = path
        self.readOnly = readOnly
        if !readOnly && path != ":memory:" { Self.makePrivateFile(path) }
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        sqlite3_extended_result_codes(db, 0)
        sqlite3_busy_timeout(db, busyTimeoutMilliseconds)
        try execute("PRAGMA foreign_keys = ON")
        if !readOnly && path != ":memory:" {
            try enableWAL(timeoutMilliseconds: busyTimeoutMilliseconds)
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Switches to WAL. Changing the journal mode does not wait on the busy handler, so two processes
    /// opening a fresh store at once would see SQLITE_BUSY; retry until the busy timeout instead.
    private func enableWAL(timeoutMilliseconds: Int32) throws(SQLiteError) {
        var waited: Int32 = 0
        while true {
            let mode: String?
            do {
                if try first("PRAGMA journal_mode")?.text("journal_mode") == "wal" { return }
                mode = try first("PRAGMA journal_mode = WAL")?.text("journal_mode")
            } catch {
                guard error.isBusy && waited < timeoutMilliseconds else { throw error }
                usleep(10_000)
                waited += 10
                continue
            }
            guard mode == "wal" else {
                throw SQLiteError(code: SQLITE_ERROR, message: "could not switch to WAL (journal mode \(mode ?? "unknown"))")
            }
            return
        }
    }

    /// Creates the file with mode 0600 if it does not exist and tightens an existing one, so the store
    /// is private from the start. SQLite gives the -wal and -shm files the database file's mode.
    static func makePrivateFile(_ path: String) {
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        if fd >= 0 {
            fchmod(fd, 0o600)
            close(fd)
        }
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc & 0xFF, message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one or more statements with no parameters and no results.
    public func execute(_ sql: String) throws(SQLiteError) {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &message)
        if rc != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message)
            throw SQLiteError(code: rc & 0xFF, message: text)
        }
    }

    /// Runs one statement with parameters, discarding any rows. Returns the number of changed rows.
    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws(SQLiteError) -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw error(rc) }
        }
        return Int(sqlite3_changes(handle))
    }

    /// Runs one statement and returns every row.
    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws(SQLiteError) -> [SQLRow] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)
        let count = sqlite3_column_count(statement)
        let columns = (0..<count).map { i in sqlite3_column_name(statement, i).map { String(cString: $0) } ?? "column\(i)" }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var values: [SQLValue] = []
            values.reserveCapacity(Int(count))
            for i in 0..<count {
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER:
                    values.append(.int(sqlite3_column_int64(statement, i)))
                case SQLITE_TEXT:
                    let length = Int(sqlite3_column_bytes(statement, i))
                    if let pointer = sqlite3_column_text(statement, i) {
                        values.append(.text(String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)))
                    } else {
                        values.append(.text(""))
                    }
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, i))
                    if let pointer = sqlite3_column_blob(statement, i) {
                        values.append(.blob(Array(UnsafeRawBufferPointer(start: pointer, count: length))))
                    } else {
                        values.append(.blob([]))
                    }
                case SQLITE_NULL:
                    values.append(.null)
                default:
                    // REAL: Cadence never stores floating point, so reading one is a schema violation.
                    throw SQLiteError(code: SQLITE_MISMATCH, message: "unexpected REAL value in column \(columns[Int(i)])")
                }
            }
            rows.append(SQLRow(columns: columns, values: values))
        }
        return rows
    }

    /// The first row of a query, or nil.
    public func first(_ sql: String, _ parameters: [SQLValue] = []) throws(SQLiteError) -> SQLRow? {
        try query(sql, parameters).first
    }

    /// Runs `body` inside a transaction, committing on success and rolling back on any error.
    /// Nested calls join the outer transaction through a savepoint. An immediate transaction cannot
    /// nest inside a deferred one: a deferred read upgrading to a write skips the busy wait.
    public func transaction<T>(_ kind: TransactionKind = .deferred, _ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            if kind == .immediate && outerKind == .deferred {
                throw SQLiteError(code: SQLITE_MISUSE, message: "an immediate transaction cannot nest inside a deferred one")
            }
            let name = "sp\(transactionDepth)"
            try execute("SAVEPOINT \(name)")
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            do {
                let result = try body()
                try execute("RELEASE \(name)")
                return result
            } catch {
                try? execute("ROLLBACK TO \(name)")
                try? execute("RELEASE \(name)")
                throw error
            }
        }
        try execute("BEGIN \(kind.rawValue)")
        transactionDepth = 1
        outerKind = kind
        defer { transactionDepth = 0 }
        // Rows inserted, updated or deleted so far on this connection, triggers included. A read, or a write
        // that changed nothing (an idempotent no-op), leaves it as it was and tells nobody.
        let changesBefore = sqlite3_total_changes(handle)
        let result: T
        do {
            result = try body()
            // SQLite can roll a transaction back on its own (disk full, interrupt); never pretend to commit.
            guard sqlite3_get_autocommit(handle) == 0 else {
                throw SQLiteError(code: SQLITE_ABORT, message: "the transaction was rolled back by SQLite")
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        // The commit is complete: a listener that opens a transaction of its own starts clean.
        transactionDepth = 0
        if sqlite3_total_changes(handle) != changesBefore { afterCommit?() }
        return result
    }

    public var isInTransaction: Bool { transactionDepth > 0 }

    /// `PRAGMA user_version`, which holds the schema version.
    public func userVersion() throws(SQLiteError) -> Int {
        Int(try first("PRAGMA user_version")?.int("user_version") ?? 0)
    }

    public func setUserVersion(_ version: Int) throws(SQLiteError) {
        try execute("PRAGMA user_version = \(version)")
    }

    /// `PRAGMA data_version`: changes when another connection commits (docs/SPEC.md section 8.2).
    public func dataVersion() throws(SQLiteError) -> Int64 {
        try first("PRAGMA data_version")?.int("data_version") ?? 0
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Copies the database into a new file (`VACUUM INTO`), used for backups.
    /// The destination must not exist: newer SQLite builds, such as the one in macOS, refuse even an empty file.
    /// SQLite creates it, so the umask is narrowed to 077 for the copy, which makes it mode 0600 from its first
    /// byte. The umask is process-wide; a file another thread creates meanwhile only comes out stricter.
    public func vacuum(into destination: String) throws(SQLiteError) {
        var existing = stat()
        guard lstat(destination, &existing) != 0 else {
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "cannot create \(destination): it already exists")
        }
        let previous = umask(0o077)
        defer { umask(previous) }
        do throws(SQLiteError) {
            try run("VACUUM INTO ?", [.text(destination)])
            guard chmod(destination, 0o600) == 0 else {
                throw SQLiteError(code: SQLITE_CANTOPEN, message: "cannot make \(destination) private")
            }
        } catch {
            unlink(destination)
            throw error
        }
    }

    // MARK: - Statements

    /// Prepares exactly one statement; trailing SQL is an error rather than silently ignored.
    private func prepare(_ sql: String) throws(SQLiteError) -> OpaquePointer? {
        var statement: OpaquePointer?
        let utf8 = Array(sql.utf8CString)
        var tailOffset = 0
        let rc = utf8.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return SQLITE_MISUSE }
            var tail: UnsafePointer<CChar>?
            let rc = sqlite3_prepare_v2(handle, base, Int32(buffer.count - 1), &statement, &tail)
            if let tail { tailOffset = base.distance(to: tail) }
            return rc
        }
        guard rc == SQLITE_OK else { throw error(rc) }
        let rest = utf8[tailOffset..<(utf8.count - 1)]
        if rest.contains(where: { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || $0 == 0x3B) }) {
            sqlite3_finalize(statement)
            throw SQLiteError(code: SQLITE_MISUSE, message: "only one statement may be prepared at a time")
        }
        return statement
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ parameters: [SQLValue], to statement: OpaquePointer?) throws(SQLiteError) {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == parameters.count else {
            throw SQLiteError(code: SQLITE_RANGE, message: "expected \(expected) parameters, got \(parameters.count)")
        }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(statement, index)
            case .int(let i):
                rc = sqlite3_bind_int64(statement, index, i)
            case .text(let s):
                // Bind by byte count, never as a NUL-terminated C string, so an embedded NUL is stored
                // whole instead of silently truncating what was hashed.
                let bytes = Array(s.utf8)
                guard bytes.count <= Int32.max else { throw SQLiteError(code: SQLITE_TOOBIG, message: "text too large") }
                rc = bytes.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress.map { base in
                        base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                            sqlite3_bind_text(statement, index, $0, Int32(buffer.count), Self.transient)
                        }
                    } ?? sqlite3_bind_text(statement, index, "", 0, Self.transient)
                }
            case .blob(let bytes):
                guard bytes.count <= Int32.max else { throw SQLiteError(code: SQLITE_TOOBIG, message: "blob too large") }
                rc = bytes.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            }
            guard rc == SQLITE_OK else { throw error(rc) }
        }
    }
}
