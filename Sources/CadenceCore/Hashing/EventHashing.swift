/// The two hashes behind every ledger event (docs/SPEC.md section 7.3), identical to
/// `tools/verify_proof.py`:
///
///     data_digest = sha256(canon(data))
///     hash        = sha256(canon({ v, seq, id, at, actor, type, subject, data_digest, prev }))
public struct EventHashing: Sendable {
    public let hasher: any ContentHasher

    public init(hasher: any ContentHasher = SHA256Hasher()) {
        self.hasher = hasher
    }

    public func dataDigest(_ data: JSONValue) throws(CanonicalJSON.Failure) -> String {
        hasher.sha256Hex(try CanonicalJSON.bytes(data))
    }

    /// The fields the event hash covers, as the JSON object that is canonicalised.
    public static func head(
        v: Int64, seq: Int64, id: String, at: String, actor: Actor, type: String, subject: String?,
        dataDigest: String, prev: String
    ) -> JSONValue {
        .object([
            "v": .int(v), "seq": .int(seq), "id": .string(id), "at": .string(at),
            "actor": .string(actor.rawValue), "type": .string(type),
            "subject": subject.map(JSONValue.string) ?? .null,
            "data_digest": .string(dataDigest), "prev": .string(prev),
        ])
    }

    public func eventHash(
        v: Int64, seq: Int64, id: String, at: String, actor: Actor, type: String, subject: String?,
        dataDigest: String, prev: String
    ) throws(CanonicalJSON.Failure) -> String {
        let head = Self.head(
            v: v, seq: seq, id: id, at: at, actor: actor, type: type, subject: subject,
            dataDigest: dataDigest, prev: prev)
        return hasher.sha256Hex(try CanonicalJSON.bytes(head))
    }

    /// Recomputes both hashes of a stored event and reports which, if any, do not match.
    public func check(_ event: Event) throws(CanonicalJSON.Failure) -> (dataOK: Bool, hashOK: Bool) {
        let digest = try dataDigest(event.data)
        let hash = try eventHash(
            v: event.v, seq: event.seq, id: event.id, at: event.at, actor: event.actor, type: event.type,
            subject: event.subject, dataDigest: event.dataDigest, prev: event.prev)
        return (digest == event.dataDigest, hash == event.hash)
    }
}
