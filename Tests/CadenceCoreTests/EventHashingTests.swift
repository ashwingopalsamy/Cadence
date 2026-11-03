import Testing

@testable import CadenceCore

@Suite struct EventHashingTests {
    static func event(from v: JSONValue) throws -> Event {
        Event(
            v: try #require(v["v"]?.intValue), seq: try #require(v["seq"]?.intValue),
            id: try #require(v["id"]?.stringValue), at: try #require(v["at"]?.stringValue),
            actor: try #require(v["actor"]?.stringValue.flatMap(Actor.init(rawValue:))),
            type: try #require(v["type"]?.stringValue), subject: v["subject"]?.stringValue,
            data: v["data"] ?? .null, dataDigest: try #require(v["data_digest"]?.stringValue),
            prev: try #require(v["prev"]?.stringValue), hash: try #require(v["hash"]?.stringValue))
    }

    @Test func sha256KnownAnswers() {
        let hasher = SHA256Hasher()
        #expect(hasher.sha256Hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hasher.sha256Hex(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func chainVectorsMatchThePythonVerifier() throws {
        let file = try Vectors.json("chains/basic.json")
        let events = try #require(file["events"]?.arrayValue).map(Self.event(from:))
        #expect(events.count == 6)
        let hashing = EventHashing()
        var prev = Event.genesisPrev
        for event in events {
            #expect(event.prev == prev, "event \(event.seq) link")
            #expect(try hashing.dataDigest(event.data) == event.dataDigest, "event \(event.seq) data digest")
            let hash = try hashing.eventHash(
                v: event.v, seq: event.seq, id: event.id, at: event.at, actor: event.actor, type: event.type,
                subject: event.subject, dataDigest: event.dataDigest, prev: event.prev)
            #expect(hash == event.hash, "event \(event.seq) hash")
            prev = event.hash
        }
        // One vector has a null subject, which must hash as JSON null, not be omitted.
        #expect(events.contains { $0.subject == nil })
    }

    @Test func validProofChainRecomputes() throws {
        let proof = try Vectors.json("proofs/valid.json")
        let events = try #require(proof["chain"]?["events"]?.arrayValue)
        let hashing = EventHashing()
        for raw in events where raw["data"] != nil {
            let event = try Self.event(from: raw)
            let result = try hashing.check(event)
            #expect(result.dataOK && result.hashOK, "event \(event.seq)")
        }
    }

    @Test func checkSpotsAnEditedPayload() throws {
        let file = try Vectors.json("chains/basic.json")
        var raw = try #require(file["events"]?.arrayValue?[3].objectValue)
        var data = try #require(raw["data"]?.objectValue)
        data["title"] = "edited"
        raw["data"] = .object(data)
        let result = try EventHashing().check(Self.event(from: .object(raw)))
        #expect(!result.dataOK)
        #expect(result.hashOK)
    }
}
