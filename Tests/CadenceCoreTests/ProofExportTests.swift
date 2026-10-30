import Foundation
import Testing

@testable import CadenceCore

@Suite struct ProofExportTests {
    static let zone = "Asia/Kolkata"
    static let repo = Vectors.root.deletingLastPathComponent().deletingLastPathComponent()

    static func entry(
        _ id: String, day: String, kind: EntryKind = .workDone, title: String, origin: Origin = .selfReported,
        ticket: Ticket? = nil, links: [Link] = [], export: ExportPolicy = .include
    ) -> Entry {
        Entry(
            id: id, day: day, kind: kind, family: EntryKind.family(for: kind, ticketClass: nil), title: title, occurredAt: "\(day)T15:12:40+05:30",
            durationS: nil, quantity: 1, ticket: ticket, links: links, tags: [], attrs: [:], origin: origin,
            source: origin == .collected ? "github" : nil, sourceRef: origin == .collected ? "github:\(id)" : nil,
            status: .accepted, backfilled: false, afterSeal: false, export: export)
    }

    static func seal(_ store: SQLiteStore, _ day: String) throws {
        let head = try #require(try store.head()).hash
        try store.append([
            EventPayload.daySealed(DaySealed(
                day: day, tz: zone, counts: [:], plan: PlanCounts(done: 0, slipped: 0, dropped: 0, moved: 0, open: 0),
                head: head)).draft(actor: .app)
        ])
    }

    /// A small October: a day before the range, two sealed workdays in it (Wed 28, Thu 29), one
    /// unsealed workday past its grace (Tue 27), a weekend, private items, a witness, and a later day.
    static func october() throws -> (SQLiteStore, ManualClock) {
        let clock = ManualClock(Timestamp.parse("2026-10-26T04:00:00Z")!)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        try store.ensureGenesis(profile: ["name": "Sample Person", "timezone": .string(zone)])
        let pr = Link(kind: .pr, url: "https://git.example.com/acme/ledger-core/pull/405")
        try store.append([
            EventPayload.entryCreated(entry("E0", day: "2026-10-26", title: "Before the range")).draft(actor: .cli)
        ])
        clock.set(Timestamp.parse("2026-10-28T10:00:00Z")!)
        try store.append([
            EventPayload.dayStarted(DayMark(day: "2026-10-28", tz: zone, at: "2026-10-28T09:41:00+05:30", source: .input)).draft(actor: .app),
            EventPayload.planAdded(PlanTask(
                id: "T1", day: "2026-10-28", position: 1, title: "Batch settlement writes", ticket: nil, estimateMin: nil,
                origin: .selfReported, carriedFrom: nil, status: .open, reason: nil, reasonNote: nil, linkedEntries: [],
                plannedAt: "2026-10-28T09:45:00+05:30", resolvedAt: nil)).draft(actor: .cli),
            EventPayload.planAdded(PlanTask(
                id: "T2", day: "2026-10-28", position: 2, title: "Draft idempotency ADR", ticket: nil, estimateMin: nil,
                origin: .selfReported, carriedFrom: nil, status: .open, reason: nil, reasonNote: nil, linkedEntries: [],
                plannedAt: "2026-10-28T09:45:00+05:30", resolvedAt: nil)).draft(actor: .cli),
            EventPayload.entryCreated(entry(
                "E1", day: "2026-10-28", kind: .prMerged, title: "ACME-482901 Batch settlement writes", origin: .collected,
                ticket: Ticket(key: "ACME-482901", class: .assigned), links: [pr])).draft(actor: .collector("github")),
            EventPayload.entryCreated(entry("E2", day: "2026-10-28", kind: .note, title: "Private note about a 1:1", export: .digest)).draft(actor: .cli),
            EventPayload.entryCreated(entry("E3", day: "2026-10-28", title: "Something excluded", export: .exclude)).draft(actor: .cli),
            EventPayload.entryCreated(entry("E4", day: "2026-10-28", kind: .reviewGiven, title: "Reviewed refunds PR", origin: .collected)).draft(actor: .collector("github")),
            EventPayload.entryCreated(entry("E5", day: "2026-10-28", title: "Deleted by mistake")).draft(actor: .cli),
            EventPayload.entryStatus(EntryStatusChange(from: .accepted, to: .deleted)).draft(actor: .cli, id: "E5"),
            EventPayload.planResolved(PlanResolved(status: .done, links: ["E1"])).draft(actor: .app, id: "T1"),
            EventPayload.genaiUsage(GenAIUsage(
                day: "2026-10-28", tool: "claude-code", model: "*", source: "transcripts", sessions: 2, requests: nil,
                tokens: TokenCounts(input: nil, output: nil, cacheRead: nil, cacheWrite: nil), costMicros: nil,
                estimated: false)).draft(actor: .collector("claude-code")),
        ])
        try seal(store, "2026-10-28")
        _ = try store.witness(day: LocalDate("2026-10-28")!, actor: .app)
        // Thu 29: sealed the next morning, inside grace.
        clock.set(Timestamp.parse("2026-10-29T06:00:00Z")!)
        try store.append([
            EventPayload.entryCreated(entry("E6", day: "2026-10-29", title: "Paired on the flaky ledger test")).draft(actor: .cli),
            EventPayload.entryUpdated(Changes(fields: ["title": Change(old: "Paired on the flaky ledger test", new: "Paired on the flaky test")])).draft(actor: .cli, id: "E6"),
        ])
        clock.set(Timestamp.parse("2026-10-30T03:00:00Z")!)
        try seal(store, "2026-10-29")
        // Sat 31 is outside the range.
        try store.append([EventPayload.entryCreated(entry("E7", day: "2026-10-31", title: "After the range")).draft(actor: .cli)])
        return (store, clock)
    }

    static func request(_ clock: ManualClock) -> ProofRequest {
        ProofRequest(
            from: LocalDate("2026-10-27")!, to: LocalDate("2026-10-30")!, zone: zone, name: "Sample Person",
            role: "Software Engineer", generatedAt: clock.now())
    }

    static func python(_ file: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", repo.appendingPathComponent("tools/verify_proof.py").path, file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func write(_ bytes: [UInt8]) throws -> URL {
        let url = TestStore.tempDirectory().appendingPathComponent("proof.json")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func embeddedVerifierIsTheTestedScript() throws {
        let script = try String(contentsOf: Self.repo.appendingPathComponent("tools/verify_proof.py"), encoding: .utf8)
        #expect(ProofText.verifierPython == script)
    }

    @Test func thePythonVerifierPassesTheExportAndFailsAnEdit() throws {
        let (store, clock) = try Self.october()
        let proof = try ProofExporter.export(store, Self.request(clock))
        let url = try Self.write(proof.bytes)
        let pass = try Self.python(url)
        #expect(pass.status == 0, "\(pass.output)")
        #expect(pass.output.contains("RESULT  PASS"))
        #expect(pass.output.contains("witness 1 codes, all found in chain"))

        // Edit one byte of a title: the verifier must fail.
        let text = String(decoding: proof.bytes, as: UTF8.self)
        let edited = text.replacingOccurrences(of: "\"title\":\"Paired on the flaky test\"", with: "\"title\":\"Paired on the flaky tests\"")
        #expect(edited != text)
        let fail = try Self.python(try Self.write(Array(edited.utf8)))
        #expect(fail.status == 1)
        #expect(fail.output.contains("export_digest does not match"))

        // Edit a payload inside the chain and fix up the digest: the payload check still catches it.
        var json = proof.json.objectValue!
        var chain = json["chain"]!.objectValue!
        var events = chain["events"]!.arrayValue!
        let index = events.firstIndex { $0.objectValue?["type"] == "entry.created" && $0.objectValue?["data"] != nil }!
        var event = events[index].objectValue!
        var data = event["data"]!.objectValue!
        data["title"] = "Changed later"
        event["data"] = .object(data)
        events[index] = .object(event)
        chain["events"] = .array(events)
        json["chain"] = .object(chain)
        json["export_digest"] = nil
        json["export_digest"] = .string(SHA256Hasher().sha256Hex(try CanonicalJSON.bytes(.object(json))))
        let redigested = try Self.python(try Self.write(try CanonicalJSON.bytes(.object(json))))
        #expect(redigested.status == 1)
        #expect(redigested.output.contains("payload changed after it was recorded"))
    }

    @Test func theSameStoreGivesTheSameBytes() throws {
        let (store, clock) = try Self.october()
        let a = try ProofExporter.export(store, Self.request(clock))
        let b = try ProofExporter.export(store, Self.request(clock))
        #expect(a.bytes == b.bytes)
        #expect(a.bytes.last == 0x0A)
        #expect(try store.eventCount() == a.events)  // export never appends
    }

    @Test func chainCarriesPayloadsOnlyInRangeAndNeverForPrivateEntries() throws {
        let (store, clock) = try Self.october()
        let proof = try ProofExporter.export(store, Self.request(clock))
        let events = proof.json.objectValue!["chain"]!.objectValue!["events"]!.arrayValue!.map { $0.objectValue! }
        #expect(events.count == Int(try store.eventCount()))
        #expect(events.map { $0["seq"]!.intValue! } == Array(1...Int64(events.count)))
        func data(_ subject: String) -> [JSONValue?] { events.filter { $0["subject"] == .string(subject) }.map { $0["data"] } }
        #expect(data("ledger") == [nil])  // genesis is recorded on the 26th
        #expect(data("entry:E0") == [nil])
        #expect(data("entry:E7") == [nil])
        #expect(data("entry:E1").allSatisfy { $0 != nil })
        #expect(data("entry:E2") == [nil])  // digest
        #expect(data("entry:E3") == [nil])  // exclude
        #expect(data("entry:E5") == [nil, nil])  // deleted
        #expect(data("entry:E6").allSatisfy { $0 != nil })
        #expect(data("task:T1").allSatisfy { $0 != nil })
        #expect(proof.privateEvents == 4)
        // Hash-only events keep every field the verifier hashes.
        for e in events {
            for key in ["v", "seq", "id", "at", "actor", "type", "subject", "data_digest", "prev", "hash"] { #expect(e[key] != nil) }
        }
    }

    @Test func daysItemsAndSummary() throws {
        let (store, clock) = try Self.october()
        let proof = try ProofExporter.export(store, Self.request(clock))
        let root = proof.json.objectValue!
        let days = root["days"]!.arrayValue!.map { $0.objectValue! }
        // Tue 27 (workday, no activity), Wed 28, Thu 29, Fri 30. No weekend in range has activity.
        #expect(days.map { $0["date"]!.stringValue! } == ["2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30"])
        let wed = days[1]
        #expect(wed["first_activity"] == "09:41")
        #expect(wed["sealed_at"]?.stringValue?.hasSuffix("+05:30") == true)
        let items = wed["items"]!.arrayValue!.map { $0.objectValue! }
        #expect(items.count == 3)  // E1, E2 (redacted), E4; E3 excluded, E5 deleted
        #expect(items[0]["title"] == "ACME-482901 Batch settlement writes")
        #expect(items[0]["ticket"] == ["key": "ACME-482901", "class": "assigned"])
        #expect(items[0]["links"] == ["https://git.example.com/acme/ledger-core/pull/405"])
        #expect(items[0]["occurred_at"] == "2026-10-28T15:12:40+05:30")
        #expect(items[1] == ["ev": items[1]["ev"]!, "last_ev": items[1]["last_ev"]!, "kind": "note", "origin": "self", "redacted": true])
        let thu = days[2]["items"]!.arrayValue![0].objectValue!
        #expect(thu["flags"]?.objectValue?["edited"] == true)
        #expect(thu["ev"] != thu["last_ev"])

        let summary = root["summary"]!.objectValue!
        // Tue 27 is past grace and unsealed, 28 and 29 sealed in grace, Fri 30 still inside its window.
        #expect(summary["sealed_workdays"]?.objectValue?["value"] == 2)
        #expect(summary["sealed_workdays"]?.objectValue?["of"] == 3)
        #expect(summary["plan_done"]?.objectValue?["value"] == 1)
        #expect(summary["plan_done"]?.objectValue?["of"] == 2)
        #expect(summary["merged_prs"]?.objectValue?["value"] == 1)
        #expect(summary["merged_prs"]?.objectValue?["assigned"] == 1)
        #expect(summary["reviews"]?.objectValue?["value"] == 1)
        #expect(summary["ai_days"]?.objectValue?["value"] == 1)
        #expect(summary["private_events"]?.objectValue?["value"] == 4)
        for (_, metric) in summary { #expect(metric.objectValue?["definition"]?.stringValue?.isEmpty == false) }

        #expect(root["witnesses"]?.arrayValue?.count == 1)
        #expect(root["witnesses"]?.arrayValue?.first?.objectValue?["where"] == "stand-up message")
        #expect(root["subject"] == ["name": "Sample Person", "role": "Software Engineer"])
        #expect(root["range"] == ["from": "2026-10-27", "to": "2026-10-30", "tz": "Asia/Kolkata"])
        #expect(root["how_to_verify"] == .string(ProofText.howToVerify))
    }

    @Test func aDeclaredWorkingSaturdayAndLeaveCountRight() throws {
        let (store, clock) = try Self.october()
        try store.append([
            EventPayload.dayDeclared(DayDeclared(day: "2026-10-27", tz: Self.zone, kind: .leavePlanned, label: "Leave")).draft(actor: .cli),
            EventPayload.dayDeclared(DayDeclared(day: "2026-10-31", tz: Self.zone, kind: .workday)).draft(actor: .cli),
        ])
        var request = Self.request(clock)
        request.to = LocalDate("2026-10-31")!
        let proof = try ProofExporter.export(store, request)
        let root = proof.json.objectValue!
        let kinds = root["days"]!.arrayValue!.map { ($0.objectValue!["date"]!.stringValue!, $0.objectValue!["kind"]!.stringValue!) }
        #expect(kinds.first { $0.0 == "2026-10-27" }?.1 == "leave_planned")
        #expect(kinds.first { $0.0 == "2026-10-31" }?.1 == "workday")
        // Leave is excluded; 28 and 29 count; 30 and 31 are inside their windows.
        #expect(root["summary"]?.objectValue?["sealed_workdays"]?.objectValue?["of"] == 2)
        let url = try Self.write(proof.bytes)
        #expect(try Self.python(url).status == 0)
    }

    @Test func badRequestsAreRefused() throws {
        let (store, clock) = try Self.october()
        var request = Self.request(clock)
        request.from = LocalDate("2026-11-01")!
        #expect(throws: CadenceError.self) { try ProofExporter.export(store, request) }
        request = Self.request(clock)
        request.zone = "Mars/Olympus"
        #expect(throws: CadenceError.self) { try ProofExporter.export(store, request) }
    }
}
