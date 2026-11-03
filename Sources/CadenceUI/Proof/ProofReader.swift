import CadenceCore
import Foundation

/// The Proof section's disk work: read a range, export it, check a file. Every call blocks, so `ProofModel` runs
/// them on a background queue.
///
/// The store is opened read-only on a fresh connection per call, as `DayStoreLoader` does, so the Proof section
/// can never start a ledger, migrate one or append to one. Export and check go through Core's `ProofExporter` and
/// `ProofVerifier`, the same code `cadence export proof` and `cadence verify` run.
public struct ProofReader: Sendable {
    public let location: StoreLocation
    public let clock: any Clock

    public init(location: StoreLocation, clock: any Clock) {
        self.location = location
        self.clock = clock
    }

    // MARK: Reading a range

    public func load(preset: ProofPreset, custom: ProofRange?) -> ProofLoad {
        if case .failed(let failure) = location { return .failed(failure) }
        do {
            let open = try openStore()
            let range = ProofRange.resolve(
                preset, today: open.journal.today(), cycleStart: open.journal.config.profile.backfillFrom, custom: custom)
            let proof = try ProofExporter.export(open.journal.store, request(range, open.journal.config))
            let inclusion = try Self.inclusion(open.journal, range)
            return .loaded(
                Self.snapshot(
                    proof.json, range: range, today: open.journal.today(), zone: open.journal.config.profile.timezone,
                    inclusion: inclusion, sources: Self.sources(open.journal.config)))
        } catch {
            return .failed(StoreFailure(error))
        }
    }

    // MARK: Export and check

    /// Builds the file for `range` now, writes it to `url` (only the person can read it), then reads it back from
    /// the disk and checks it with Core's verifier. If the file fails, the ledger is checked again, so the card can
    /// say whether the fault is in the file or in the log.
    public func export(_ range: ProofRange, to url: URL) -> ProofOutcome {
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent().lastPathComponent
        let open: Open
        let proof: ProofFile
        do {
            open = try openStore()
            proof = try ProofExporter.export(open.journal.store, request(range, open.journal.config))
        } catch {
            return Self.unwritten(name, folder, because: String(localized: "Cadence could not read its log, so nothing was written."), error.message)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard Self.write(proof.bytes, to: url), let written = FileManager.default.contents(atPath: url.path) else {
            return Self.unwritten(name, folder, because: String(localized: "Cadence could not write \(name)."), "write failed")
        }
        let report = ProofVerifier.verify(bytes: Array(written))
        var outcome = Self.outcome(report, action: .exported, name: name, folder: folder, file: Array(written))
        if !report.passed {
            if let chain = try? open.journal.store.verifyChain() {
                outcome.ledger = chain.ok ? .verified(events: Int(chain.events)) : .failed(Self.words(chain.problems.first ?? "").text)
            }
        }
        return outcome
    }

    /// Checks a file with Core's verifier. It never opens the store.
    public static func check(_ url: URL) -> ProofOutcome {
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent().lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return ProofOutcome(
                action: .checked, fileName: name, folderName: folder, passed: false, codes: 0, exportDigest: nil,
                failure: String(localized: "Cadence could not open \(name)."), failingEvent: nil, fails: ["could not read the file"], ledger: nil)
        }
        let bytes = Array(data)
        return outcome(ProofVerifier.verify(bytes: bytes), action: .checked, name: name, folder: folder, file: bytes)
    }

    // MARK: Pieces, internal so the tests reach them

    struct Open {
        let journal: Journal
    }

    func openStore() throws(CadenceError) -> Open {
        let roots: FileRoots
        switch location {
        case .found(let found): roots = found
        case .failed(let failure): throw .io(failure.detail)
        }
        guard FileManager.default.fileExists(atPath: roots.database.path) else {
            throw .notFound(String(localized: "There is no cadence.db in \(roots.home.path)"))
        }
        let config = try ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0
        let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
        let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, readOnly: true)
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids, actor: .app, writesGenesis: false)
        return Open(journal: journal)
    }

    /// The request `cadence export proof` builds for the same range.
    func request(_ range: ProofRange, _ config: Config) -> ProofRequest {
        ProofRequest(
            from: range.from, to: range.to, zone: config.profile.timezone, name: config.profile.name,
            role: config.profile.role, rules: DayRules(config: config), generatedAt: clock.now())
    }

    /// Accepted entries in range by their export policy, as the exporter reads them.
    static func inclusion(_ journal: Journal, _ range: ProofRange) throws(CadenceError) -> ProofInclusion {
        var counts: [ExportPolicy: Int] = [:]
        var cursor: String?
        repeat {
            let page = try journal.query(
                EntryQuery(from: range.from, to: range.to, statuses: [.accepted], searchNotes: false, cursor: cursor,
                    limit: EntryQuery.maxLimit))
            for entry in page.entries { counts[entry.export, default: 0] += 1 }
            cursor = page.next
        } while cursor != nil
        return ProofInclusion(titled: counts[.include] ?? 0, digest: counts[.digest] ?? 0, excluded: counts[.exclude] ?? 0)
    }

    /// Collectors turned on in config, by name.
    static func sources(_ config: Config) -> [String] {
        config.collectors.filter(\.enabled).map(\.name)
    }

    /// The cards' numbers, read from the file itself.
    static func snapshot(
        _ file: JSONValue, range: ProofRange, today: LocalDate, zone: String, inclusion: ProofInclusion, sources: [String]
    ) -> ProofSnapshot {
        let summary = file["summary"]
        func int(_ key: String, _ field: String) -> Int? { summary?[key]?[field]?.intValue.map(Int.init) }
        let chain = file["chain"]?["events"]?.arrayValue ?? []
        let withPayload = chain.filter { $0["data"] != nil }.count
        let days = file["days"]?.arrayValue ?? []
        let timeZone = TimeZone(identifier: zone) ?? .current

        // The preview: the latest day that lists items, latest first.
        var previewDay: LocalDate?
        var preview: [ProofPreviewItem] = []
        if let day = days.last(where: { !($0["items"]?.arrayValue ?? []).isEmpty }) {
            previewDay = day["date"]?.stringValue.flatMap(LocalDate.init)
            let items = (day["items"]?.arrayValue ?? []).map(previewItem)
            preview = Array(items.sorted { ($0.time ?? "") > ($1.time ?? "") }.prefix(ProofSnapshot.previewLimit))
        }

        // Codes: the file's witnesses, timed by their checkpoint events in the chain.
        var copiedAt: [String: String] = [:]
        for event in chain where event["type"]?.stringValue == "witness.checkpoint" {
            guard let hash = event["hash"]?.stringValue, let at = event["at"]?.stringValue.flatMap(Timestamp.parse) else { continue }
            copiedAt[Witness.code(of: hash)] = Timestamp.clockTime(at, in: timeZone)
        }
        var codeByDate: [String: String] = [:]
        for w in file["witnesses"]?.arrayValue ?? [] {
            if let date = w["date"]?.stringValue, let code = w["code"]?.stringValue { codeByDate[date] = code }
        }
        let sealed = days.compactMap { day -> LocalDate? in
            guard day["seal_ev"]?.stringValue != nil else { return nil }
            return day["date"]?.stringValue.flatMap(LocalDate.init)
        }
        let codeDays = sealed.sorted(by: >).prefix(ProofSnapshot.codeLimit).map { date in
            let code = codeByDate[date.description]
            return ProofCodeDay(date: date, code: code, copiedAt: code.flatMap { copiedAt[$0] })
        }

        return ProofSnapshot(
            range: range, today: today, zone: zone,
            sealedWorkdays: int("sealed_workdays", "value"), countedWorkdays: int("sealed_workdays", "of"),
            eventsInRange: withPayload + (int("private_events", "value") ?? 0), chainEvents: chain.count,
            inclusion: inclusion, planDone: int("plan_done", "value"), planned: int("plan_done", "of"),
            previewDay: previewDay, preview: preview,
            codesCopied: Set(codeByDate.keys).count, sealedDays: sealed.count, codeDays: Array(codeDays), sources: sources)
    }

    static func previewItem(_ item: JSONValue) -> ProofPreviewItem {
        let kind = item["kind"]?.stringValue.flatMap(EntryKind.init(rawValue:))
        let redacted = item["redacted"]?.boolValue == true
        // "2026-10-28T15:12:40+05:30": the file already writes local time, so the clock is characters 11 to 15.
        let time = item["occurred_at"]?.stringValue.flatMap { text -> String? in
            guard text.count >= 16 else { return nil }
            return String(text.dropFirst(11).prefix(5))
        }
        return ProofPreviewItem(
            id: item["ev"]?.stringValue ?? UUID().uuidString, time: time, kind: kind,
            family: item["family"]?.stringValue.flatMap(Family.init(rawValue:)) ?? kind?.defaultFamily,
            title: redacted ? nil : item["title"]?.stringValue, ticket: redacted ? nil : item["ticket"]?["key"]?.stringValue,
            origin: item["origin"]?.stringValue ?? "-")
    }

    static func outcome(_ report: ProofReport, action: ProofOutcome.Action, name: String, folder: String?, file: [UInt8])
        -> ProofOutcome
    {
        let json = try? JSONParser.parse(bytes: file)
        let first = report.fails.first { Self.eventNumber($0) != nil } ?? report.fails.first
        let words = first.map(Self.words)
        return ProofOutcome(
            action: action, fileName: name, folderName: folder, passed: report.passed,
            codes: json?["witnesses"]?.arrayValue?.count ?? 0, exportDigest: json?["export_digest"]?.stringValue,
            failure: words?.text, failingEvent: words?.event, fails: report.fails, ledger: nil)
    }

    private static func unwritten(_ name: String, _ folder: String, because text: String, _ detail: String) -> ProofOutcome {
        ProofOutcome(
            action: .exported, fileName: name, folderName: folder, passed: false, codes: 0, exportDigest: nil, failure: text,
            failingEvent: nil, fails: [detail], ledger: nil)
    }

    /// The event a verifier line names ("event 214: ..."), if any.
    static func eventNumber(_ line: String) -> Int? {
        guard line.hasPrefix("event "), let colon = line.firstIndex(of: ":") else { return nil }
        return Int(line[line.index(line.startIndex, offsetBy: 6)..<colon])
    }

    /// A verifier line as one plain sentence for the card, and the event it names.
    static func words(_ line: String) -> (text: String, event: Int?) {
        if let n = eventNumber(line) {
            let what = line[line.index(after: line.firstIndex(of: ":")!)...].trimmingCharacters(in: .whitespaces)
            let text: String
            switch what {
            case "event hash mismatch": text = String(localized: "Event \(n) does not match its hash.")
            case "payload changed after it was recorded", "payload digest mismatch": text = String(localized: "Event \(n) was changed after it was recorded.")
            case "sequence gap or reorder": text = String(localized: "Event \(n) is out of order, or one before it is missing.")
            case "does not link to the event before it": text = String(localized: "Event \(n) does not link to the event before it.")
            default: text = String(localized: "Event \(n): \(what).")
            }
            return (text, n)
        }
        if line.hasPrefix("export_digest") { return (String(localized: "This file was edited after it was exported."), nil) }
        if line.hasPrefix("the file is not a readable proof") { return (String(localized: "This is not a readable proof file."), nil) }
        if line.hasPrefix("unknown format") { return (String(localized: "This is not a Cadence proof file."), nil) }
        guard let head = line.first else { return (String(localized: "This file did not pass its check."), nil) }
        let sentence = head.uppercased() + line.dropFirst()
        return (sentence.hasSuffix(".") ? sentence : sentence + ".", nil)
    }

    /// Writes the file at exactly the URL the save panel granted, mode 0600. The sandbox grants that one path, so
    /// there is no temporary file beside it; the check that follows reads the file back, so a short write fails it.
    static func write(_ bytes: [UInt8], to url: URL) -> Bool {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        var ok = fchmod(fd, 0o600) == 0
        var offset = 0
        while ok && offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { ok = false } else { offset += n }
        }
        ok = ok && fsync(fd) == 0
        return close(fd) == 0 && ok
    }
}
