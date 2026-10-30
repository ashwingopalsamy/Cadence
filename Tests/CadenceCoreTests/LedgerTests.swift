import Foundation
import Testing

@testable import CadenceCore

@Suite struct LedgerTests {
    static func draft(_ n: Int, actor: Actor = .cli) -> EventDraft {
        EventDraft(type: "test.event", subject: "test:\(n)", data: ["n": .int(Int64(n)), "text": "ACME / São Paulo"], actor: actor)
    }

    @Test func genesisMustComeFirst() throws {
        let store = try TestStore.make()
        #expect(throws: CadenceError.self) { try store.append([Self.draft(1)]) }
        #expect(try store.ensureGenesis(profile: ["name": "Sample Person"]))
        #expect(try !store.ensureGenesis(profile: ["name": "Sample Person"]))
        #expect(throws: CadenceError.self) {
            try store.append([EventDraft(type: "ledger.genesis", subject: "ledger", data: [:], actor: .app)])
        }
    }

    @Test func appendBuildsAGaplessLinkedChain() throws {
        let clock = ManualClock(TestStore.start)
        let store = try TestStore.make(clock: clock)
        try store.ensureGenesis(profile: [:])
        for n in 1...20 {
            clock.advance(by: 0.5)
            try store.append([Self.draft(n)])
        }
        try store.append((21...25).map { Self.draft($0) })
        let events = try store.events(after: 0, limit: 100)
        #expect(events.map(\.seq) == Array(1...26))
        #expect(events[0].prev == Event.genesisPrev)
        for (a, b) in zip(events, events.dropFirst()) { #expect(b.prev == a.hash) }
        #expect(events[1].at == "2026-09-21T14:13:20.500Z")
        #expect(try store.head()?.seq == 26)
        let report = try store.verifyChain(batch: 7)
        #expect(report.ok, "\(report.problems)")
        #expect(report.events == 26)
    }

    @Test func storedPayloadIsCanonicalAndRoundTrips() throws {
        let store = try TestStore.make()
        try store.ensureGenesis(profile: [:])
        let draft = EventDraft(type: "test.event", subject: nil, data: ["b": [1, 2], "a": "x/y"], actor: .mcp)
        let written = try store.append([draft])[0]
        let raw = try #require(try store.db.first("SELECT data FROM events WHERE seq = 2")?.text("data"))
        #expect(raw == #"{"a":"x/y","b":[1,2]}"#)
        let read = try #require(try store.events(after: 1, limit: 1).first)
        #expect(read == written)
        #expect(read.subject == nil)
        #expect(read.actor == .mcp)
    }

    @Test func verifyChainSpotsTamperingBelowTheTriggers() throws {
        let store = try TestStore.make()
        try store.ensureGenesis(profile: [:])
        try store.append((1...5).map { Self.draft($0) })
        // Someone with the file can drop the trigger; the chain still tells.
        try store.db.execute("DROP TRIGGER events_no_update")
        try store.db.run(#"UPDATE events SET data = '{"n":99,"text":"edited"}' WHERE seq = 3"#)
        let report = try store.verifyChain()
        #expect(report.problems == ["event 3: payload digest mismatch"])
    }

    @Test func invalidActorNamesAreRefused() throws {
        let store = try TestStore.make()
        try store.ensureGenesis(profile: [:])
        #expect(throws: CadenceError.validation("invalid actor name: collector:BAD NAME")) {
            try store.append([EventDraft(type: "test.event", subject: nil, data: [:], actor: .collector("BAD NAME"))])
        }
    }

    @Test func rejectedAppendWritesNothing() throws {
        let store = try TestStore.make()
        try store.ensureGenesis(profile: [:])
        let bad = EventDraft(type: "test.event", subject: nil, data: ["big": .int(Int64.max)], actor: .cli)
        #expect(throws: CadenceError.self) { try store.append([Self.draft(1), bad]) }
        #expect(try store.eventCount() == 1)
    }

    @Test func projectorFailureRollsBackTheEvent() throws {
        struct Failing: Projector {
            func apply(_ event: Event, in db: SQLiteDatabase) throws(CadenceError) {
                if event.type == "test.event" { throw .validation("no") }
            }
            func reset(in db: SQLiteDatabase) throws(CadenceError) {}
        }
        let store = try TestStore.make(projector: Failing())
        try store.ensureGenesis(profile: [:])
        #expect(throws: CadenceError.validation("no")) { try store.append([Self.draft(1)]) }
        #expect(try store.eventCount() == 1)
    }

    @Test func concurrentConnectionsKeepTheChainLinear() async throws {
        let path = TestStore.tempDirectory().appendingPathComponent("cadence.db").path
        let ids = CountingIDs()
        try SQLiteStore(path: path, clock: ManualClock(TestStore.start), ids: ids).ensureGenesis(profile: [:])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<4 {
                group.addTask {
                    let store = try SQLiteStore(
                        path: path, clock: ManualClock(TestStore.start), ids: ids, busyTimeoutMilliseconds: 10_000)
                    for n in 0..<50 { try store.append([Self.draft(writer * 1000 + n)]) }
                }
            }
            try await group.waitForAll()
        }
        let report = try TestStore.make(path: path).verifyChain()
        #expect(report.ok, "\(report.problems)")
        #expect(report.events == 201)
    }
}

@Suite struct LedgerAuditTests {
    @Test func controlCharactersInTypeOrSubjectAreRefused() throws {
        let store = try TestStore.make()
        try store.ensureGenesis(profile: [:])
        #expect(throws: CadenceError.validation("invalid event subject")) {
            try store.append([EventDraft(type: "test.event", subject: "entry:a\u{0}b", data: [:], actor: .cli)])
        }
        #expect(throws: CadenceError.validation("invalid event type")) {
            try store.append([EventDraft(type: "Test\u{0}", subject: nil, data: [:], actor: .cli)])
        }
        #expect(try store.verifyChain().ok)
    }

    @Test func textWithNULIsStoredWhole() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try db.execute("CREATE TABLE t (s TEXT)")
        try db.run("INSERT INTO t VALUES (?)", [.text("a\u{0}b")])
        #expect(try db.first("SELECT length(CAST(s AS BLOB)) AS n FROM t")?.int("n") == 3)
    }

    @Test func freshStoreOpenedConcurrentlyNeverFails() async throws {
        for _ in 0..<10 {
            let path = TestStore.tempDirectory().appendingPathComponent("cadence.db").path
            let ids = CountingIDs()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        let store = try SQLiteStore(path: path, clock: ManualClock(TestStore.start), ids: ids)
                        try store.ensureGenesis(profile: [:])
                    }
                }
                try await group.waitForAll()
            }
            let store = try TestStore.make(path: path)
            #expect(try store.eventCount() == 1)
        }
    }

    @Test func immediateCannotNestInsideDeferred() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        #expect(throws: SQLiteError.self) {
            try db.transaction(.deferred) { try db.transaction(.immediate) {} }
        }
        try db.transaction(.immediate) { try db.transaction(.immediate) {} }
    }

    @Test func trailingSQLIsAnError() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try db.execute("CREATE TABLE t (i INTEGER)")
        #expect(throws: SQLiteError.self) { try db.run("INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)") }
        try db.run("INSERT INTO t VALUES (1);")
        #expect(try db.query("SELECT i FROM t").count == 1)
    }

    @Test func storeAndBackupFilesArePrivate() throws {
        let dir = TestStore.tempDirectory()
        let path = dir.appendingPathComponent("cadence.db").path
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
        let store = try TestStore.make(path: path)
        try store.ensureGenesis(profile: [:])
        func mode(_ p: String) throws -> Int {
            ((try FileManager.default.attributesOfItem(atPath: p))[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        #expect(try mode(path) == 0o600)
        #expect(try mode(path + "-wal") == 0o600)
        let backup = dir.appendingPathComponent("backup.db").path
        try store.db.vacuum(into: backup)
        #expect(try mode(backup) == 0o600)
    }

    @Test func verifyChainReportsDamagedRowsInsteadOfThrowing() throws {
        let store = try TestStore.make()
        try store.ensureGenesis(profile: [:])
        try store.append([LedgerTests.draft(1), LedgerTests.draft(2)])
        try store.db.execute("DROP TRIGGER events_no_update")
        try store.db.run("UPDATE events SET actor = 'evil' WHERE seq = 2")
        try store.db.run("UPDATE events SET prev = 'x' WHERE seq = 3")
        let report = try store.verifyChain()
        #expect(report.problems.contains { $0.hasPrefix("event 2: unreadable") })
        #expect(report.problems.contains("event 3: does not link to the event before it"))
    }

    @Test func schemaMatchesTheSpecDDL() throws {
        let spec = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("docs/SPEC.md"), encoding: .utf8)
        let start = try #require(spec.range(of: "CREATE TABLE events ("))
        let end = try #require(spec.range(of: "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);", range: start.lowerBound..<spec.endIndex))
        let fromSpec = String(spec[start.lowerBound..<end.upperBound])
        func normalise(_ s: String) -> [String] {
            s.split(separator: "\n").map { line -> String in
                let code = line.components(separatedBy: "--").first ?? ""
                return code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }.filter { !$0.isEmpty }
        }
        let schemaStart = try #require(Schema.v1.range(of: "CREATE TABLE events ("))
        #expect(normalise(fromSpec) == normalise(String(Schema.v1[schemaStart.lowerBound...])))
    }
}
