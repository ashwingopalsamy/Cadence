import Foundation

/// Makes event ids. `ULIDGenerator` is the production source.
public protocol IdentifierSource: AnyObject, Sendable {
    func next() -> String
}

/// The Cadence store: one SQLite file holding the append-only ledger and its projections
/// (docs/SPEC.md sections 7.3 and 8.2).
///
/// Appends take `BEGIN IMMEDIATE`, read the head inside the transaction, and write the new events
/// and their projection updates before committing, so SQLite serialises every writer in every
/// process and the chain stays linear with gapless sequence numbers.
public final class SQLiteStore: Store {
    public let db: SQLiteDatabase
    public let clock: any Clock
    public let ids: any IdentifierSource
    public let projector: any Projector
    let hashing: EventHashing

    /// Opens the store at `path`. Read-write opens create the file and migrate it; read-only opens
    /// never write and accept any schema version for reading.
    public init(
        path: String, clock: any Clock, ids: any IdentifierSource, projector: any Projector = NoProjector(),
        hashing: EventHashing = EventHashing(), readOnly: Bool = false, busyTimeoutMilliseconds: Int32 = 3000
    ) throws(CadenceError) {
        do {
            db = try SQLiteDatabase(path: path, readOnly: readOnly, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
        } catch {
            throw error.cadenceError
        }
        self.clock = clock
        self.ids = ids
        self.projector = projector
        self.hashing = hashing
        if !readOnly {
            // Every writer tells the others after its commit (docs/SPEC.md section 8.2). An in-memory store has
            // no other process to tell.
            if path != ":memory:" {
                let poster = DarwinStoreChangePoster()
                db.afterCommit = { poster.postStoreChanged() }
            }
            try Migrator.migrate(db)
        }
    }

    public func schemaVersion() throws -> Int {
        do {
            return try db.userVersion()
        } catch {
            throw error.cadenceError
        }
    }

    /// Writes `ledger.genesis` if the ledger is empty. Returns true when it wrote one.
    @discardableResult
    public func ensureGenesis(profile: JSONValue, actor: Actor = .app) throws(CadenceError) -> Bool {
        try transact { () throws(CadenceError) -> Bool in
            if try self.headRow() != nil { return false }
            let created = Timestamp.utc(self.clock.now())
            let data: JSONValue = ["created": .string(created), "app_version": .string(CadenceVersion.app), "profile": profile]
            _ = try self.appendLocked([EventDraft(type: "ledger.genesis", subject: "ledger", data: data, actor: actor)])
            return true
        }
    }

    @discardableResult
    public func append(_ drafts: [EventDraft]) throws -> [Event] {
        try append(drafts, then: { _ in })
    }

    /// Appends events and then runs `after` inside the same transaction, so callers can make
    /// further reads that must see a consistent store. Throws `.storeBusy` past the busy timeout.
    @discardableResult
    public func append(_ drafts: [EventDraft], then after: ([Event]) throws(CadenceError) -> Void) throws(CadenceError) -> [Event] {
        guard !drafts.isEmpty else { return [] }
        return try transact { () throws(CadenceError) -> [Event] in
            let events = try self.appendLocked(drafts)
            try after(events)
            return events
        }
    }

    /// Runs `body` in one `BEGIN IMMEDIATE` transaction (or joins the current one), mapping SQLite
    /// failures to Cadence errors.
    public func transact<T>(_ body: () throws(CadenceError) -> T) throws(CadenceError) -> T {
        do {
            return try db.transaction(.immediate) { () throws -> T in
                // Checked under the write lock, so a newer binary cannot migrate between check and write.
                try Migrator.checkWritable(self.db)
                return try body()
            }
        } catch let error as CadenceError {
            throw error
        } catch let error as SQLiteError {
            throw error.isConstraint ? .integrity(error.message) : error.cadenceError
        } catch {
            throw .io(String(describing: error))
        }
    }

    /// Runs `body` in one read transaction, so a multi-query read sees a single snapshot even while
    /// other processes append. Works on read-only stores too.
    public func transactRead<T>(_ body: () throws(CadenceError) -> T) throws(CadenceError) -> T {
        do {
            return try db.transaction(.deferred) { () throws -> T in try body() }
        } catch let error as CadenceError {
            throw error
        } catch let error as SQLiteError {
            throw error.cadenceError
        } catch {
            throw .io(String(describing: error))
        }
    }

    private func appendLocked(_ drafts: [EventDraft]) throws(CadenceError) -> [Event] {
        var (seq, prev) = try headRow() ?? (0, Event.genesisPrev)
        if seq == 0, drafts.first?.type != "ledger.genesis" {
            throw .integrity("the ledger is empty; ledger.genesis must be the first event")
        }
        var written: [Event] = []
        written.reserveCapacity(drafts.count)
        for draft in drafts {
            if seq > 0 && draft.type == "ledger.genesis" {
                throw .integrity("ledger.genesis can only be the first event")
            }
            guard Actor(rawValue: draft.actor.rawValue) == draft.actor else {
                throw .validation("invalid actor name: \(draft.actor.rawValue)")
            }
            try Self.validate(type: draft.type, subject: draft.subject)
            seq += 1
            let id = ids.next()
            let at = Timestamp.utc(clock.now())
            let canonical: [UInt8]
            let dataDigest: String
            let hash: String
            do {
                canonical = try CanonicalJSON.bytes(draft.data)
                dataDigest = hashing.hasher.sha256Hex(canonical)
                hash = try hashing.eventHash(
                    v: Event.currentVersion, seq: seq, id: id, at: at, actor: draft.actor, type: draft.type,
                    subject: draft.subject, dataDigest: dataDigest, prev: prev)
            } catch {
                throw .validation("event payload is not canonical JSON: \(error)")
            }
            let event = Event(
                v: Event.currentVersion, seq: seq, id: id, at: at, actor: draft.actor, type: draft.type,
                subject: draft.subject, data: draft.data, dataDigest: dataDigest, prev: prev, hash: hash)
            do {
                try db.run(
                    "INSERT INTO events (seq, id, v, at, actor, type, subject, data, data_digest, prev, hash) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    [.int(seq), .text(id), .int(event.v), .text(at), .text(draft.actor.rawValue), .text(draft.type),
                     SQLValue(draft.subject), .text(String(decoding: canonical, as: UTF8.self)), .text(dataDigest),
                     .text(prev), .text(hash)])
            } catch {
                throw error.isConstraint ? .integrity(error.message) : error.cadenceError
            }
            try projector.apply(event, in: db)
            written.append(event)
            prev = hash
        }
        return written
    }

    /// Event types: lowercase ASCII words joined by dots, underscores or hyphens. Subjects: printable,
    /// no control characters, at most 200 bytes. Both are hashed, so they must store exactly as given.
    static func validate(type: String, subject: String?) throws(CadenceError) {
        let typeBytes = Array(type.utf8)
        let typeOK = (1...64).contains(typeBytes.count) && (0x61...0x7A).contains(typeBytes[0])
            && typeBytes.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D }
        guard typeOK else { throw .validation("invalid event type") }
        if let subject {
            guard (1...200).contains(subject.utf8.count),
                subject.unicodeScalars.allSatisfy({ !($0.properties.generalCategory == .control) })
            else { throw .validation("invalid event subject") }
        }
    }

    private func headRow() throws(CadenceError) -> (Int64, String)? {
        do {
            guard let row = try db.first("SELECT seq, hash FROM events ORDER BY seq DESC LIMIT 1"),
                let seq = row.int("seq"), let hash = row.text("hash")
            else { return nil }
            return (seq, hash)
        } catch {
            throw error.cadenceError
        }
    }

    public func head() throws -> Event? {
        try readEvents("SELECT * FROM events ORDER BY seq DESC LIMIT 1", []).first
    }

    public func events(after seq: Int64, limit: Int) throws -> [Event] {
        try readEvents("SELECT * FROM events WHERE seq > ? ORDER BY seq LIMIT ?", [.int(seq), .int(Int64(limit))])
    }

    /// Every event for one subject, in order (edit history for an entry, task or day).
    public func events(subject: String) throws(CadenceError) -> [Event] {
        try readEvents("SELECT * FROM events WHERE subject = ? ORDER BY seq", [.text(subject)])
    }

    /// The event with this hash, if any.
    public func event(hash: String) throws(CadenceError) -> Event? {
        try readEvents("SELECT * FROM events WHERE hash = ?", [.text(hash)]).first
    }

    public func eventCount() throws(CadenceError) -> Int64 {
        do {
            return try db.first("SELECT COUNT(*) AS n FROM events")?.int("n") ?? 0
        } catch {
            throw error.cadenceError
        }
    }

    func readEvents(_ sql: String, _ parameters: [SQLValue]) throws(CadenceError) -> [Event] {
        let rows: [SQLRow]
        do {
            rows = try db.query(sql, parameters)
        } catch {
            throw error.cadenceError
        }
        return try rows.map { (row) throws(CadenceError) -> Event in try Self.decode(row) }
    }

    static func decode(_ row: SQLRow) throws(CadenceError) -> Event {
        guard let seq = row.int("seq"), let id = row.text("id"), let v = row.int("v"), let at = row.text("at"),
            let actorRaw = row.text("actor"), let type = row.text("type"), let dataText = row.text("data"),
            let dataDigest = row.text("data_digest"), let prev = row.text("prev"), let hash = row.text("hash")
        else { throw .integrity("event row is missing a column") }
        guard let actor = Actor(rawValue: actorRaw) else { throw .integrity("event \(seq) has an unknown actor") }
        let data: JSONValue
        do {
            data = try JSONParser.parse(dataText)
        } catch {
            throw .integrity("event \(seq) payload is not valid JSON: \(error)")
        }
        return Event(
            v: v, seq: seq, id: id, at: at, actor: actor, type: type, subject: row.text("subject"), data: data,
            dataDigest: dataDigest, prev: prev, hash: hash)
    }
}

/// The result of walking the stored chain.
public struct ChainReport: Sendable, Equatable {
    public var events: Int64
    public var head: String?
    public var problems: [String]
    public var ok: Bool { problems.isEmpty }
}

extension SQLiteStore {
    /// Recomputes every digest and hash and checks sequence, links and the genesis rule
    /// (`cadence doctor`). Reads raw rows, so a damaged row is reported, never thrown.
    public func verifyChain(batch: Int = 2000) throws(CadenceError) -> ChainReport {
        var report = ChainReport(events: 0, head: nil, problems: [])
        var expectedSeq: Int64 = 1
        var prev = Event.genesisPrev
        var after: Int64 = 0
        while true {
            let rows: [SQLRow]
            do {
                rows = try db.query("SELECT * FROM events WHERE seq > ? ORDER BY seq LIMIT ?", [.int(after), .int(Int64(batch))])
            } catch {
                throw error.cadenceError
            }
            if rows.isEmpty { break }
            for row in rows {
                let seq = row.int("seq") ?? -1
                let hash = row.text("hash") ?? ""
                if seq != expectedSeq { report.problems.append("event \(seq): sequence gap, expected \(expectedSeq)") }
                if row.text("prev") != prev { report.problems.append("event \(seq): does not link to the event before it") }
                if seq == 1 && row.text("type") != "ledger.genesis" { report.problems.append("event 1: is not ledger.genesis") }
                do {
                    let event = try Self.decode(row)
                    let check = try hashing.check(event)
                    if !check.dataOK { report.problems.append("event \(seq): payload digest mismatch") }
                    if !check.hashOK { report.problems.append("event \(seq): event hash mismatch") }
                } catch {
                    report.problems.append("event \(seq): unreadable: \(error)")
                }
                expectedSeq = seq + 1
                prev = hash
                after = seq
                report.events += 1
                report.head = hash
            }
        }
        return report
    }
}

extension ULIDGenerator: IdentifierSource {}
