/// One ledger event as stored in `events` and exported in proof files (docs/SPEC.md section 7.3).
///
///     data_digest = sha256(canon(data))
///     hash        = sha256(canon({ v, seq, id, at, actor, type, subject, data_digest, prev }))
///     prev        = hash of event seq-1, or 64 zeros for genesis
public struct Event: Sendable, Equatable {
    public let v: Int64
    public let seq: Int64
    /// ULID.
    public let id: String
    /// Recorded time: RFC 3339, UTC, milliseconds, `Z` suffix.
    public let at: String
    public let actor: Actor
    public let type: String
    public let subject: String?
    public let data: JSONValue
    public let dataDigest: String
    public let prev: String
    public let hash: String

    public init(
        v: Int64, seq: Int64, id: String, at: String, actor: Actor, type: String, subject: String?,
        data: JSONValue, dataDigest: String, prev: String, hash: String
    ) {
        self.v = v
        self.seq = seq
        self.id = id
        self.at = at
        self.actor = actor
        self.type = type
        self.subject = subject
        self.data = data
        self.dataDigest = dataDigest
        self.prev = prev
        self.hash = hash
    }

    /// The `prev` of the genesis event.
    public static let genesisPrev = String(repeating: "0", count: 64)

    /// The current event format version.
    public static let currentVersion: Int64 = 1
}

/// An event before the ledger assigns its sequence number, id, time and hashes.
public struct EventDraft: Sendable, Equatable {
    public var type: String
    public var subject: String?
    public var data: JSONValue
    public var actor: Actor

    public init(type: String, subject: String?, data: JSONValue, actor: Actor) {
        self.type = type
        self.subject = subject
        self.data = data
        self.actor = actor
    }
}
