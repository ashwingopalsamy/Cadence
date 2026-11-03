import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The Proof section against the October demo in a temporary home. Every file goes to a temporary folder:
/// proof files are never written into the repository.
@Suite struct ProofTests {
    struct FixedClock: Clock {
        let instant: Date
        func now() -> Date { instant }
    }

    /// Fri 30 Oct 2026, 09:12 in Kolkata: the morning after the demo's last sealed day.
    static let now = Timestamp.parse("2026-10-30T03:42:00Z")!
    static let today = LocalDate("2026-10-30")!
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A home with the October demo seeded into it, and the config the reader will load.
    struct Home {
        let roots: FileRoots

        init() throws {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cadence-proof-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            roots = FileRoots(home: folder)
            try ConfigStore.save(DemoSeed.config(), to: roots.config)
            let clock = ManualClock(Timestamp.parse(DemoSeed.startInstant)!)
            let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1))
            let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
            let journal = try Journal(store: store, config: DemoSeed.config(), clock: clock, ids: ids)
            try DemoSeed.seed(into: journal, clock: clock)
        }

        var reader: ProofReader { ProofReader(location: .found(roots), clock: FixedClock(instant: ProofTests.now)) }

        /// A file in a folder of its own, outside the store.
        func file(_ name: String) -> URL {
            let folder = roots.home.appendingPathComponent("chosen", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent(name)
        }

        func remove() { try? FileManager.default.removeItem(at: roots.home) }
    }

    static func snapshot(_ home: Home, _ preset: ProofPreset = .month, custom: ProofRange? = nil) throws -> ProofSnapshot {
        guard case .loaded(let snapshot) = home.reader.load(preset: preset, custom: custom) else {
            throw CadenceError.integrity("the proof range did not load")
        }
        return snapshot
    }

    // MARK: Ranges

    @Test func presetsResolveToTheRangesTheSummaryUses() {
        func range(_ preset: ProofPreset, _ today: LocalDate = Self.today, cycle: LocalDate? = nil, custom: ProofRange? = nil) -> String {
            let r = ProofRange.resolve(preset, today: today, cycleStart: cycle, custom: custom)
            return "\(r.from)..\(r.to)"
        }
        // Weeks start Monday; Fri 30 Oct is in the week of Mon 26 Oct.
        #expect(range(.week) == "2026-10-26..2026-10-30")
        #expect(range(.week, LocalDate("2026-10-26")!) == "2026-10-26..2026-10-26")
        #expect(range(.month) == "2026-10-01..2026-10-30")
        // The cycle starts on 1 October unless the profile names a start.
        #expect(range(.cycle) == "2026-10-01..2026-10-30")
        #expect(range(.cycle, LocalDate("2027-02-10")!) == "2026-10-01..2027-02-10")
        #expect(range(.cycle, cycle: LocalDate("2026-04-01")!) == "2026-04-01..2026-10-30")
        // Custom is put in order and never ends after today.
        let backwards = ProofRange(from: LocalDate("2026-10-20")!, to: LocalDate("2026-10-05")!)
        #expect(range(.custom, custom: backwards) == "2026-10-05..2026-10-20")
        let future = ProofRange(from: LocalDate("2026-10-12")!, to: LocalDate("2026-11-20")!)
        #expect(range(.custom, custom: future) == "2026-10-12..2026-10-30")
        // Custom with nothing chosen yet reads as the month.
        #expect(range(.custom) == "2026-10-01..2026-10-30")
        #expect(ProofRange(from: LocalDate("2026-10-01")!, to: LocalDate("2026-10-29")!).fileName == "2026-10-01_2026-10-29.cadence-proof.json")
    }

    @Test func rangesReadInSentencesWithoutDashes() {
        let gb = Locale(identifier: "en_GB")
        let october = ProofRange(from: LocalDate("2026-10-01")!, to: LocalDate("2026-10-29")!)
        #expect(ProofCopy.span(october, locale: gb) == "1 to 29 Oct")
        #expect(ProofCopy.span(ProofRange(from: LocalDate("2026-09-28")!, to: LocalDate("2026-10-04")!), locale: gb) == "28 Sept to 4 Oct"
            || ProofCopy.span(ProofRange(from: LocalDate("2026-09-28")!, to: LocalDate("2026-10-04")!), locale: gb) == "28 Sep to 4 Oct")
        #expect(ProofCopy.title(.month, range: october, locale: gb) == "Your October, ready to hand over.")
        #expect(ProofCopy.title(.week, range: october, locale: gb) == "Your week, ready to hand over.")
        for text in [ProofCopy.span(october, locale: gb), ProofCopy.limits, ProofCopy.notCopied] {
            #expect(!text.contains("\u{2013}") && !text.contains("\u{2014}"))
        }
    }

    // MARK: What is included

    /// The card's rows are Core's export policies: `include` items carry titles and tickets, `digest` items are
    /// listed with the title kept back, `exclude` items are not listed. Counted from the store, they match the file.
    @Test func whatIsIncludedMapsOntoCoresExportPolicies() throws {
        let home = try Home()
        defer { home.remove() }
        let snapshot = try Self.snapshot(home)
        let open = try home.reader.openStore()
        let proof = try ProofExporter.export(open.journal.store, home.reader.request(snapshot.range, open.journal.config))
        let items = (proof.json["days"]?.arrayValue ?? []).flatMap { $0["items"]?.arrayValue ?? [] }
        let redacted = items.filter { $0["redacted"]?.boolValue == true }
        let titled = items.filter { $0["redacted"] == nil }

        #expect(snapshot.inclusion.count(.include) == titled.count)
        #expect(snapshot.inclusion.count(.digest) == redacted.count)
        #expect(snapshot.inclusion.count(.exclude) == 0)
        #expect(!redacted.isEmpty, "the demo's notes are digest by default")
        #expect(redacted.allSatisfy { $0["title"] == nil && $0["ticket"] == nil })
        #expect(titled.allSatisfy { $0["title"]?.stringValue != nil })

        let rows = ProofCopy.inclusion(snapshot.inclusion)
        #expect(rows.map(\.value) == ["\(titled.count) items", "\(redacted.count) items", "0 items", "Hashes only", "Included"])
    }

    @Test func thePreviewCarriesTheFilesRedaction() throws {
        let home = try Home()
        defer { home.remove() }
        let snapshot = try Self.snapshot(home)
        #expect(snapshot.previewDay == LocalDate("2026-10-29"))
        #expect(!snapshot.preview.isEmpty && snapshot.preview.count <= ProofSnapshot.previewLimit)
        #expect(snapshot.preview.map { $0.time ?? "" } == snapshot.preview.map { $0.time ?? "" }.sorted(by: >))
        let stub = ProofReader.previewItem(["ev": "ab", "kind": "note", "origin": "self", "redacted": true, "title": "secret"])
        #expect(stub.redacted && stub.title == nil && stub.family == .presence)
    }

    // MARK: Coverage and codes

    @Test func coverageCountsSealedWorkdaysEventsAndCodes() throws {
        let home = try Home()
        defer { home.remove() }
        let snapshot = try Self.snapshot(home)
        let open = try home.reader.openStore()
        let proof = try ProofExporter.export(open.journal.store, home.reader.request(snapshot.range, open.journal.config))

        // Spec 12.1: 19 of 19 sealed, 61 of 73 planned done. Friday 30 Oct is still inside its window.
        #expect(snapshot.sealedWorkdays == 19)
        #expect(snapshot.countedWorkdays == 19)
        #expect(snapshot.planDone == 61)
        #expect(snapshot.planned == 73)
        #expect(ProofCopy.percent(61, of: 73) == 84)
        #expect(ProofCopy.percent(nil, of: 73) == nil && ProofCopy.percent(0, of: 0) == nil)
        #expect(snapshot.chainEvents == proof.events)
        let chain = proof.json["chain"]?["events"]?.arrayValue ?? []
        #expect(snapshot.eventsInRange == chain.filter { $0["data"] != nil }.count + proof.privateEvents)
        #expect(snapshot.eventsInRange <= snapshot.chainEvents)

        // The demo copies a stand-up on every sealed day.
        #expect(snapshot.sealedDays == 19)
        #expect(snapshot.codesCopied == proof.witnesses)
        #expect(snapshot.codesCopied == 19)
        #expect(snapshot.codeDays.count == ProofSnapshot.codeLimit)
        #expect(snapshot.codeDays.first?.date == LocalDate("2026-10-29"))
        #expect(snapshot.codeDays.allSatisfy { $0.code?.count == Witness.codeLength && $0.copiedAt?.count == 5 })
        #expect(ProofCopy.codesLine(snapshot) == "19 of 19 days have a code you copied into a stand-up. Those can be checked against that message.")

        let week = try Self.snapshot(home, .week)
        #expect(week.range == ProofRange(from: LocalDate("2026-10-26")!, to: Self.today))
        #expect(week.sealedWorkdays == 4)
        #expect(week.eventsInRange < snapshot.eventsInRange)
    }

    @Test func noSourcesTurnedOnSaysSo() {
        #expect(ProofCopy.sourcesLine([]) == "No sources are turned on, so nothing else does either.")
        var config = Config.defaults(timezone: "Asia/Kolkata")
        config.collectors = [Config.Collector(name: "github", builtin: "github"), Config.Collector(name: "old", enabled: false, builtin: "github")]
        #expect(ProofReader.sources(config) == ["github"])
        #expect(ProofCopy.sourcesLine(ProofReader.sources(config)) == "Only sources you approved do: github.")
    }

    // MARK: Export and check

    @Test func theOctoberExportIsWrittenAndPassesCoresVerifier() throws {
        let home = try Home()
        defer { home.remove() }
        let october = ProofRange(from: LocalDate("2026-10-01")!, to: LocalDate("2026-10-29")!)
        let url = home.file(october.fileName)
        let outcome = home.reader.export(october, to: url)

        #expect(outcome.passed, "\(outcome.fails)")
        #expect(outcome.action == .exported)
        #expect(outcome.fileName == "2026-10-01_2026-10-29.cadence-proof.json")
        #expect(outcome.codes == 19)
        #expect(outcome.failure == nil && outcome.ledger == nil)
        let bytes = try Data(contentsOf: url)
        let json = try JSONParser.parse(bytes: Array(bytes))
        #expect(outcome.exportDigest == json["export_digest"]?.stringValue)
        #expect(outcome.digestLine?.hasPrefix("SHA-256 ") == true)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(ProofCopy.outcomeHead(outcome) == "Exported and checked.")
        #expect(ProofCopy.outcomeBody(outcome) == "\(outcome.fileName), in chosen. Chain intact, and 19 codes can be checked against your stand-ups.")

        // Check a file reads the same file the same way.
        let checked = ProofReader.check(url)
        #expect(checked.passed && checked.action == .checked && checked.codes == 19)
    }

    @Test(.enabled(if: ProofTests.python != nil, "python3 is not installed"))
    func theAppsExportPassesThePythonVerifier() throws {
        let home = try Home()
        defer { home.remove() }
        let october = ProofRange(from: LocalDate("2026-10-01")!, to: LocalDate("2026-10-29")!)
        let url = home.file(october.fileName)
        #expect(home.reader.export(october, to: url).passed)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProofTests.python!)
        process.arguments = ["-I", Self.repo.appendingPathComponent("tools/verify_proof.py").path, url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(output)")
        #expect(output.contains("RESULT  PASS: the chain is complete"))
        #expect(output.contains("witness 19 codes, all found in chain"))
    }

    @Test func aTamperedFileFailsAndNamesTheEvent() throws {
        let home = try Home()
        defer { home.remove() }
        let october = ProofRange(from: LocalDate("2026-10-01")!, to: LocalDate("2026-10-29")!)
        let url = home.file(october.fileName)
        #expect(home.reader.export(october, to: url).passed)

        // Change who recorded event 214, as an edit by hand would.
        guard case .object(var root) = try JSONParser.parse(bytes: Array(try Data(contentsOf: url))),
            case .object(var chain)? = root["chain"], case .array(var events)? = chain["events"],
            case .object(var event)? = events.dropFirst(213).first, let actor = event["actor"]?.stringValue
        else { throw CadenceError.integrity("the export has no event 214") }
        event["actor"] = .string(actor == "app" ? "cli" : "app")
        events[213] = .object(event)
        chain["events"] = .array(events)
        root["chain"] = .object(chain)
        let tampered = home.file("tampered.cadence-proof.json")
        try Data(try CanonicalJSON.bytes(.object(root))).write(to: tampered)

        let outcome = ProofReader.check(tampered)
        #expect(!outcome.passed)
        #expect(outcome.failingEvent == 214)
        #expect(outcome.failure == "Event 214 does not match its hash.")
        #expect(outcome.fails.contains { $0.hasPrefix("export_digest") }, "the digest catches the edit too")
        #expect(ProofCopy.outcomeHead(outcome) == "Event 214 does not match its hash.")
        #expect(ProofCopy.outcomeBody(outcome) == "tampered.cadence-proof.json did not pass the checks the open verifier runs.")
    }

    @Test func failuresReadAsPlainSentences() {
        #expect(ProofReader.words("event 7: payload changed after it was recorded") == ("Event 7 was changed after it was recorded.", 7))
        #expect(ProofReader.words("event 12: sequence gap or reorder").event == 12)
        #expect(ProofReader.words("export_digest does not match the file: it was edited after export").text == "This file was edited after it was exported.")
        #expect(ProofReader.words("the file is not a readable proof: ValueError x").text == "This is not a readable proof file.")
        #expect(ProofReader.words("2026-10-05: seal_ev is not this day's seal").text == "2026-10-05: seal_ev is not this day's seal.")
        var failed = ProofOutcome(
            action: .exported, fileName: "a.json", folderName: "x", passed: false, codes: 0, exportDigest: nil,
            failure: "Event 214 does not match its hash.", failingEvent: 214, fails: [], ledger: .verified(events: 412))
        #expect(ProofCopy.outcomeBody(failed) == "Cadence checked your ledger again, and all 412 events verify, so the fault is in this file.")
        failed.ledger = nil
        #expect(ProofCopy.outcomeBody(failed) == "Nothing you can share was written.")
        #expect(ProofReader.check(URL(fileURLWithPath: "/nonexistent/cadence-proof.json")).passed == false)
    }

    @Test func aMissingStoreIsTheErrorStateNeverAnotherPlace() {
        let reader = ProofReader(
            location: .found(FileRoots(home: FileManager.default.temporaryDirectory.appendingPathComponent("cadence-none-\(UUID().uuidString)"))),
            clock: FixedClock(instant: Self.now))
        guard case .failed(let failure) = reader.load(preset: .month, custom: nil) else {
            Issue.record("expected the error state")
            return
        }
        #expect(failure.kind == .missing)
    }

    // MARK: The model

    @MainActor @Test func theModelReadsOffTheMainThreadAndFollowsThePreset() async throws {
        let home = try Home()
        defer { home.remove() }
        let model = ProofModel(reader: home.reader)
        #expect(model.load == .loading)
        await model.reload()
        #expect(model.snapshot?.range == ProofRange(from: LocalDate("2026-10-01")!, to: Self.today))
        #expect(model.suggestedFileName == "2026-10-01_2026-10-30.cadence-proof.json")
        await model.select(.week)
        #expect(model.preset == .week)
        #expect(model.snapshot?.range.from == LocalDate("2026-10-26"))
        await model.select(.custom)
        #expect(model.custom?.from == LocalDate("2026-10-26"), "custom starts from the range on screen")
        await model.setCustom(ProofRange(from: LocalDate("2026-10-05")!, to: LocalDate("2026-10-09")!))
        #expect(model.snapshot?.range == ProofRange(from: LocalDate("2026-10-05")!, to: LocalDate("2026-10-09")!))
        #expect(model.snapshot?.sealedWorkdays == 5)

        await model.export(to: home.file("week.cadence-proof.json"))
        #expect(model.outcome?.passed == true)
        #expect(model.working == nil)
        await model.select(.month)
        #expect(model.outcome == nil, "a new range clears the last result")
    }

    static let python: String? = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}
