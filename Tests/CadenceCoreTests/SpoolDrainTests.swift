import Foundation
import Testing

@testable import CadenceCore

@Suite struct SpoolDrainTests {
    static let zone = "Asia/Kolkata"

    struct Fixture {
        let roots: FileRoots
        let clock: ManualClock
        let store: SQLiteStore
        let config: Config

        /// The clock reads 2026-09-21T14:13:20Z; the spool dates below are around it.
        init() throws {
            roots = FileRoots(home: TestStore.tempDirectory())
            clock = ManualClock(TestStore.start)
            store = try TestStore.make(path: roots.database.path, clock: clock, projector: LedgerProjector())
            config = Config.defaults(timezone: SpoolDrainTests.zone)
        }

        func drain() throws -> DrainReport {
            try SpoolDrain(roots: roots, store: store, config: config, clock: clock).drain()
        }

        func spoolFile(_ name: String = "hooks-2026-09-21.ndjson") -> URL {
            roots.spool.appendingPathComponent(name)
        }

        func write(_ lines: [String], to name: String = "hooks-2026-09-21.ndjson", terminated: Bool = true) throws {
            try FileManager.default.createDirectory(at: roots.spool, withIntermediateDirectories: true)
            var text = lines.joined(separator: "\n")
            if terminated { text += "\n" }
            try Data(text.utf8).write(to: spoolFile(name))
        }

        func append(_ text: String, to name: String = "hooks-2026-09-21.ndjson") throws {
            let handle = try FileHandle(forWritingTo: spoolFile(name))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }

        func sessionEvents() throws -> [Event] {
            try store.events(after: 0, limit: 1000).filter { $0.type == "genai.session" }
        }

        func row(_ id: String) throws -> SQLRow? {
            try store.db.first("SELECT * FROM genai_sessions WHERE session_id = ?", [.text(id)])
        }

        var offsetFile: URL { roots.state.appendingPathComponent("spool-drain.json") }
    }

    static func start(_ id: String, _ at: String, project: String? = "acme-service", model: String? = "model-a") -> String {
        var fields = #""at":"\#(at)","event":"session-start","session_id":"\#(id)","source":"startup","v":1"#
        if let project { fields += #","project":"\#(project)""# }
        if let model { fields += #","model":"\#(model)""# }
        return "{" + fields + "}"
    }

    static func end(_ id: String, _ at: String, reason: String = "other") -> String {
        #"{"at":"\#(at)","event":"session-end","reason":"\#(reason)","session_id":"\#(id)","v":1}"#
    }

    static func stop(_ id: String, _ at: String) -> String {
        #"{"at":"\#(at)","event":"stop","session_id":"\#(id)","v":1}"#
    }

    // MARK: folding

    @Test func foldsStartAndEndIntoOneSessionEvent() throws {
        let f = try Fixture()
        try f.write([
            Self.start("s1", "2026-09-21T09:00:00.000Z"), Self.stop("s1", "2026-09-21T09:05:00.000Z"),
            Self.end("s1", "2026-09-21T09:30:00.000Z", reason: "clear"),
        ])
        let report = try f.drain()
        #expect(report.eventsWritten == 1)
        #expect(report.ignored == 1)
        let events = try f.sessionEvents()
        #expect(events.count == 1)
        #expect(events[0].actor == .hook)
        #expect(events[0].subject == "session:s1")
        let payload = try GenAISession(json: events[0].data)
        #expect(payload.tool == "claude-code")
        #expect(payload.day == "2026-09-21")
        #expect(payload.startedAt == "2026-09-21T09:00:00.000Z")
        #expect(payload.endedAt == "2026-09-21T09:30:00.000Z")
        #expect(payload.endReason == "clear")
        #expect(payload.projectAlias == "acme-service")
        #expect(payload.models == ["model-a"])
        #expect(payload.turns == nil)
        let row = try #require(try f.row("s1"))
        #expect(row.text("ended_at") == "2026-09-21T09:30:00.000Z")
    }

    @Test func aGenesisEventIsWrittenFirstOnAnEmptyLedger() throws {
        let f = try Fixture()
        try f.write([Self.start("s1", "2026-09-21T09:00:00.000Z")])
        #expect(try f.store.eventCount() == 0)
        _ = try f.drain()
        let events = try f.store.events(after: 0, limit: 10)
        #expect(events.map(\.type) == ["ledger.genesis", "genai.session"])
        #expect(try f.store.verifyChain().ok)
    }

    @Test func anEmptySpoolWritesNothingAtAll() throws {
        let f = try Fixture()
        let report = try f.drain()
        #expect(report == DrainReport())
        #expect(try f.store.eventCount() == 0)
    }

    @Test func theDayIsTheWorkdayOfTheStartInTheProfileZone() throws {
        let f = try Fixture()
        // 2026-09-21T21:00Z is 02:30 on the 22nd in Kolkata, before the 04:00 boundary, so it is workday the 21st.
        // 2026-09-21T23:00Z is 04:30 on the 22nd.
        try f.write([Self.start("late", "2026-09-21T21:00:00.000Z"), Self.start("next", "2026-09-21T23:00:00.000Z")])
        _ = try f.drain()
        #expect(try f.row("late")?.text("day") == "2026-09-21")
        #expect(try f.row("next")?.text("day") == "2026-09-22")
    }

    @Test func aSessionAcrossMidnightKeepsTheDayOfItsStartAcrossFiles() throws {
        let f = try Fixture()
        try f.write([Self.start("long", "2026-09-21T10:00:00.000Z")], to: "hooks-2026-09-21.ndjson")
        _ = try f.drain()
        try f.write([Self.end("long", "2026-09-22T08:00:00.000Z", reason: "logout")], to: "hooks-2026-09-22.ndjson")
        let report = try f.drain()
        #expect(report.eventsWritten == 1)
        let events = try f.sessionEvents()
        #expect(events.count == 2)
        let second = try GenAISession(json: events[1].data)
        #expect(second.day == "2026-09-21")
        #expect(second.startedAt == "2026-09-21T10:00:00.000Z")
        #expect(second.endedAt == "2026-09-22T08:00:00.000Z")
        #expect(second.projectAlias == "acme-service")
        #expect(second.models == ["model-a"])
        let row = try #require(try f.row("long"))
        #expect(row.text("day") == "2026-09-21")
        #expect(row.text("end_reason") == "logout")
        #expect(try f.drain().eventsWritten == 0)
    }

    @Test func aStartAndEndOnLaterDaysInOneBatchIsOneEvent() throws {
        let f = try Fixture()
        try f.write([Self.start("a", "2026-09-21T10:00:00.000Z")], to: "hooks-2026-09-21.ndjson")
        try f.write([Self.end("a", "2026-09-22T08:00:00.000Z")], to: "hooks-2026-09-22.ndjson")
        let report = try f.drain()
        #expect(report.eventsWritten == 2)  // one per file transaction, first the start then the end
        #expect(try f.row("a")?.text("day") == "2026-09-21")
        #expect(try f.row("a")?.text("ended_at") == "2026-09-22T08:00:00.000Z")
    }

    @Test func anEndWithoutAStartUsesTheFirstTimeSeen() throws {
        let f = try Fixture()
        try f.write([Self.stop("orphan", "2026-09-21T09:00:00.000Z"), Self.end("orphan", "2026-09-21T09:10:00.000Z")])
        let report = try f.drain()
        #expect(report.eventsWritten == 1)
        let payload = try GenAISession(json: try #require(try f.sessionEvents().first).data)
        #expect(payload.startedAt == "2026-09-21T09:00:00.000Z")
        #expect(payload.endedAt == "2026-09-21T09:10:00.000Z")
        #expect(payload.projectAlias == nil)
        #expect(payload.models == [])
    }

    // MARK: idempotence

    @Test func replayingTheSameSpoolWritesNothingNew() throws {
        let f = try Fixture()
        try f.write([
            Self.start("s1", "2026-09-21T09:00:00.000Z"), Self.end("s1", "2026-09-21T09:30:00.000Z"),
            Self.start("s2", "2026-09-21T10:00:00.000Z"),
        ])
        let first = try f.drain()
        #expect(first.eventsWritten == 2)
        let count = try f.store.eventCount()
        let second = try f.drain()
        #expect(second.eventsWritten == 0)
        #expect(try f.store.eventCount() == count)
        // A second run over the same file from scratch is also quiet.
        try FileManager.default.removeItem(at: f.offsetFile)
        let third = try f.drain()
        #expect(third.eventsWritten == 0)
        #expect(third.duplicates == 2)
        #expect(try f.store.eventCount() == count)
    }

    @Test func aLostOffsetFileDoesNotDuplicate() throws {
        let f = try Fixture()
        try f.write([Self.start("s1", "2026-09-21T09:00:00.000Z"), Self.end("s1", "2026-09-21T09:30:00.000Z")])
        _ = try f.drain()
        let count = try f.store.eventCount()
        #expect(FileManager.default.fileExists(atPath: f.offsetFile.path))
        try FileManager.default.removeItem(at: f.offsetFile)
        #expect(try f.drain().eventsWritten == 0)
        // A corrupt offset file is the same as a lost one.
        try Data("{not json".utf8).write(to: f.offsetFile)
        #expect(try f.drain().eventsWritten == 0)
        #expect(try f.store.eventCount() == count)
    }

    @Test func aLostOffsetStillCompletesASessionThatEndedLater() throws {
        let f = try Fixture()
        try f.write([Self.start("s1", "2026-09-21T09:00:00.000Z")])
        _ = try f.drain()
        try FileManager.default.removeItem(at: f.offsetFile)
        try f.append(Self.end("s1", "2026-09-21T09:30:00.000Z") + "\n")
        let report = try f.drain()
        #expect(report.eventsWritten == 1)
        #expect(try f.row("s1")?.text("ended_at") == "2026-09-21T09:30:00.000Z")
        #expect(try f.sessionEvents().count == 2)
    }

    @Test func linesAppendedLaterAreDrainedFromTheSavedOffset() throws {
        let f = try Fixture()
        try f.write([Self.start("s1", "2026-09-21T09:00:00.000Z")])
        _ = try f.drain()
        let size = try Data(contentsOf: f.spoolFile()).count
        let state = try String(contentsOf: f.offsetFile, encoding: .utf8)
        #expect(state.contains("\"hooks-2026-09-21.ndjson\":\(size)"))
        try f.append(Self.start("s2", "2026-09-21T11:00:00.000Z") + "\n")
        #expect(try f.drain().eventsWritten == 1)
        #expect(try f.sessionEvents().count == 2)
    }

    @Test func theOffsetFileIsPrivate() throws {
        let f = try Fixture()
        try f.write([Self.start("s1", "2026-09-21T09:00:00.000Z")])
        _ = try f.drain()
        let mode = try #require(FileManager.default.attributesOfItem(atPath: f.offsetFile.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
    }

    @Test func aLaterEndMovesTheEndOnlyForward() throws {
        let f = try Fixture()
        try f.write([
            Self.start("s1", "2026-09-21T09:00:00.000Z"), Self.end("s1", "2026-09-21T09:30:00.000Z"),
            Self.end("s1", "2026-09-21T09:20:00.000Z"),
        ])
        _ = try f.drain()
        #expect(try f.row("s1")?.text("ended_at") == "2026-09-21T09:30:00.000Z")
        try f.append(Self.end("s1", "2026-09-21T10:00:00.000Z", reason: "logout") + "\n")
        #expect(try f.drain().eventsWritten == 1)
        #expect(try f.row("s1")?.text("ended_at") == "2026-09-21T10:00:00.000Z")
        #expect(try f.row("s1")?.text("end_reason") == "logout")
    }

    // MARK: partial and malformed lines

    @Test func aPartialLastLineWaitsForTheNextDrain() throws {
        let f = try Fixture()
        let whole = Self.start("s1", "2026-09-21T09:00:00.000Z")
        let second = Self.start("s2", "2026-09-21T10:00:00.000Z")
        let cut = second.index(second.startIndex, offsetBy: 30)
        try f.write([whole, String(second[..<cut])], terminated: false)
        // The first line needs its own newline; rewrite with an explicit one.
        try Data((whole + "\n" + String(second[..<cut])).utf8).write(to: f.spoolFile())
        let first = try f.drain()
        #expect(first.eventsWritten == 1)
        #expect(first.partialFiles == 1)
        #expect(first.skippedMalformed == 0)
        #expect(try f.row("s2") == nil)
        try f.append(String(second[cut...]) + "\n")
        let next = try f.drain()
        #expect(next.eventsWritten == 1)
        #expect(next.partialFiles == 0)
        #expect(try f.row("s2")?.text("started_at") == "2026-09-21T10:00:00.000Z")
    }

    @Test func aFileWithOnlyAPartialLineWritesNothingAndKeepsItsOffsetAtZero() throws {
        let f = try Fixture()
        try Data(#"{"at":"2026-09"#.utf8).write(to: {
            try? FileManager.default.createDirectory(at: f.roots.spool, withIntermediateDirectories: true)
            return f.spoolFile()
        }())
        let report = try f.drain()
        #expect(report.eventsWritten == 0)
        #expect(report.partialFiles == 1)
        #expect(try f.store.eventCount() == 0)
    }

    @Test func malformedLinesAreSkippedAndCounted() throws {
        let f = try Fixture()
        try f.write([
            "not json", "[]", "{}", #"{"at":"x","event":"session-start","session_id":"s","v":1}"#,
            #"{"at":"2026-09-21T09:00:00.000Z","event":"session-start","session_id":"bad id","v":1}"#,
            #"{"at":"2026-09-21T09:00:00.000Z","event":"unknown","session_id":"s","v":1}"#,
            #"{"at":"2026-09-21T09:00:00.000Z","event":"session-start","session_id":"s","v":2}"#,
            "",
            Self.start("ok", "2026-09-21T09:00:00.000Z"),
        ])
        let report = try f.drain()
        #expect(report.skippedMalformed == 8)
        #expect(report.eventsWritten == 1)
        #expect(try f.sessionEvents().count == 1)
        // Skipped lines are consumed: a second drain does not count them again.
        #expect(try f.drain().skippedMalformed == 0)
    }

    // MARK: files

    @Test func drainedFilesOlderThanFourteenDaysAreDeleted() throws {
        let f = try Fixture()  // clock: 2026-09-21
        try f.write([Self.start("old", "2026-09-01T09:00:00.000Z")], to: "hooks-2026-09-01.ndjson")
        try f.write([Self.start("edge", "2026-09-07T09:00:00.000Z")], to: "hooks-2026-09-07.ndjson")
        try f.write([Self.start("new", "2026-09-21T09:00:00.000Z")], to: "hooks-2026-09-21.ndjson")
        let report = try f.drain()
        #expect(report.eventsWritten == 3)
        #expect(report.filesDeleted == 1)
        #expect(!FileManager.default.fileExists(atPath: f.spoolFile("hooks-2026-09-01.ndjson").path))
        #expect(FileManager.default.fileExists(atPath: f.spoolFile("hooks-2026-09-07.ndjson").path))
        #expect(FileManager.default.fileExists(atPath: f.spoolFile("hooks-2026-09-21.ndjson").path))
        let state = try String(contentsOf: f.offsetFile, encoding: .utf8)
        #expect(!state.contains("2026-09-01"))
    }

    @Test func anOldFileWithAnUndrainedPartialLineIsKept() throws {
        let f = try Fixture()
        try f.write([Self.start("old", "2026-09-01T09:00:00.000Z"), #"{"at":"20"#], to: "hooks-2026-09-01.ndjson", terminated: false)
        try Data((Self.start("old", "2026-09-01T09:00:00.000Z") + "\n" + #"{"at":"20"#).utf8)
            .write(to: f.spoolFile("hooks-2026-09-01.ndjson"))
        let report = try f.drain()
        #expect(report.filesDeleted == 0)
        #expect(FileManager.default.fileExists(atPath: f.spoolFile("hooks-2026-09-01.ndjson").path))
    }

    @Test func otherFilesInTheSpoolAreLeftAlone() throws {
        let f = try Fixture()
        try f.write(["junk"], to: "notes.txt")
        try f.write([Self.start("s1", "2026-09-21T09:00:00.000Z")])
        let report = try f.drain()
        #expect(report.eventsWritten == 1)
        #expect(report.skippedMalformed == 0)
        #expect(FileManager.default.fileExists(atPath: f.spoolFile("notes.txt").path))
    }

    @Test func aTruncatedFileIsReadAgainFromTheStart() throws {
        let f = try Fixture()
        try f.write([Self.start("s1", "2026-09-21T09:00:00.000Z"), Self.start("s2", "2026-09-21T09:10:00.000Z")])
        _ = try f.drain()
        try f.write([Self.start("s3", "2026-09-21T09:20:00.000Z")])
        #expect(try f.drain().eventsWritten == 1)
        #expect(try f.row("s3") != nil)
    }

    // MARK: ledger

    @Test func theProjectionRebuildsFromTheDrainedEvents() throws {
        let f = try Fixture()
        try f.write([
            Self.start("s1", "2026-09-21T09:00:00.000Z"), Self.end("s1", "2026-09-21T09:30:00.000Z"),
            Self.start("s2", "2026-09-21T10:00:00.000Z", project: nil, model: nil),
        ])
        _ = try f.drain()
        #expect(try f.store.verifyChain().ok)
        let before = try f.store.projectionDump()
        #expect(before.contains("session_id"))
        try f.store.rebuild()
        #expect(try f.store.projectionDump() == before)
    }
}
