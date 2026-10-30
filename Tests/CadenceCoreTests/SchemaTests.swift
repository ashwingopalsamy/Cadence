import Foundation
import Testing

@testable import CadenceCore

@Suite struct SchemaTests {
    @Test func swiftSchemaMatchesTheSQLFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CadenceCore/Store/Schema.sql")
        let file = try String(contentsOf: url, encoding: .utf8)
        #expect(Schema.v1 == file)
    }

    @Test func freshStoreIsAtTheCurrentVersion() throws {
        let store = try TestStore.make()
        #expect(try store.schemaVersion() == Schema.currentVersion)
        let tables = try store.db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").compactMap { $0.text("name") }
        #expect(tables == ["days", "entries", "events", "genai_sessions", "genai_usage", "meta", "plan_tasks", "presence_spans"])
    }

    @Test func eventsCannotBeUpdatedOrDeleted() throws {
        let store = try TestStore.make()
        try store.ensureGenesis(profile: ["name": "Sample Person"])
        #expect(throws: SQLiteError.self) { try store.db.run("UPDATE events SET type = 'x'") }
        #expect(throws: SQLiteError.self) { try store.db.run("DELETE FROM events") }
        do {
            try store.db.run("DELETE FROM events WHERE seq = 1")
        } catch {
            #expect(error.message.contains("ledger is append-only"))
        }
        #expect(try store.eventCount() == 1)
    }

    @Test func migrationIsIdempotentAcrossOpens() throws {
        let path = TestStore.tempDirectory().appendingPathComponent("cadence.db").path
        _ = try TestStore.make(path: path)
        let again = try TestStore.make(path: path)
        #expect(try again.schemaVersion() == Schema.currentVersion)
    }

    @Test func refusesToWriteANewerSchema() throws {
        let path = TestStore.tempDirectory().appendingPathComponent("cadence.db").path
        let store = try TestStore.make(path: path)
        try store.ensureGenesis(profile: [:])
        try store.db.setUserVersion(Schema.currentVersion + 1)
        #expect(throws: CadenceError.schemaTooNew(found: Schema.currentVersion + 1, supported: Schema.currentVersion)) {
            _ = try TestStore.make(path: path)
        }
        // An already-open connection refuses too.
        #expect(throws: CadenceError.schemaTooNew(found: Schema.currentVersion + 1, supported: Schema.currentVersion)) {
            try store.append([EventDraft(type: "test.event", subject: nil, data: [:], actor: .cli)])
        }
        // Reading is still allowed.
        let reader = try SQLiteStore(path: path, clock: ManualClock(TestStore.start), ids: CountingIDs(), readOnly: true)
        #expect(try reader.eventCount() == 1)
    }
}
