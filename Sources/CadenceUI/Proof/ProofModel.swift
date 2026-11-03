import CadenceCore
import Dispatch
import Foundation
import Observation

/// The Proof section's range presets (docs/SPEC.md section 4.6).
public enum ProofPreset: String, CaseIterable, Sendable, Identifiable {
    case week, month, cycle, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .week: String(localized: "This week")
        case .month: String(localized: "This month")
        case .cycle: String(localized: "This cycle")
        case .custom: String(localized: "Custom")
        }
    }
}

/// The days a proof covers, first and last included.
public struct ProofRange: Sendable, Equatable {
    public var from: LocalDate
    public var to: LocalDate

    public init(from: LocalDate, to: LocalDate) {
        self.from = from
        self.to = to
    }

    /// The presets read as `cadence summary` reads week, month and cycle (`SummaryRange.resolve`), so the proof
    /// and the summary always cover the same days. A custom range is put in order and never ends after today,
    /// as `cadence export proof` refuses a future day.
    public static func resolve(_ preset: ProofPreset, today: LocalDate, cycleStart: LocalDate?, custom: ProofRange?) -> ProofRange {
        let summary: SummaryRange
        switch preset {
        case .week: summary = .week
        case .month: summary = .month
        case .cycle: summary = .cycle
        case .custom:
            guard let custom else { return resolve(.month, today: today, cycleStart: cycleStart, custom: nil) }
            let first = min(custom.from, custom.to, today)
            let last = min(max(custom.from, custom.to), today)
            return ProofRange(from: first, to: last)
        }
        let bounds = summary.resolve(today: today, cycleStart: cycleStart)
        return ProofRange(from: bounds.from, to: bounds.to)
    }

    /// The file name `cadence export proof` writes by default.
    public var fileName: String { "\(from)_\(to).cadence-proof.json" }
}

/// What the file includes, read from Core's export policies (docs/SPEC.md section 12.1). A proof request has no
/// switches: each entry carries its policy from the day it was written (notes `digest`, everything else
/// `include`), and private free text and AI records follow fixed rules in the exporter. So this is a statement
/// of what will leave, not a set of toggles.
public struct ProofInclusion: Sendable, Equatable {
    /// Accepted entries with policy `include`: listed with title, ticket key and links.
    public var titled: Int
    /// Accepted entries with policy `digest`: listed as a stub with kind and origin, the title kept back.
    public var digest: Int
    /// Accepted entries with policy `exclude`: left out of the days, their events kept in the chain as hashes.
    public var excluded: Int

    public init(titled: Int, digest: Int, excluded: Int) {
        self.titled = titled
        self.digest = digest
        self.excluded = excluded
    }

    /// The count for one Core policy.
    public func count(_ policy: ExportPolicy) -> Int {
        switch policy {
        case .include: titled
        case .digest: digest
        case .exclude: excluded
        }
    }
}

/// One item as the file shows it to a manager.
public struct ProofPreviewItem: Sendable, Equatable, Identifiable {
    /// The item's `ev`, the hash of the event that created it.
    public var id: String
    /// "HH:MM" local, or nil when the item has no time.
    public var time: String?
    public var kind: EntryKind?
    public var family: Family?
    /// Nil when the file keeps the title back (`redacted`).
    public var title: String?
    public var ticket: String?
    public var origin: String

    public var redacted: Bool { title == nil }
}

/// A sealed day and the code, if any, copied into that day's stand-up.
public struct ProofCodeDay: Sendable, Equatable, Identifiable {
    public var date: LocalDate
    public var code: String?
    /// "HH:MM" local time of the witness checkpoint, when there is one.
    public var copiedAt: String?

    public var id: String { date.description }
}

/// Everything the four cards show for one range, read from a proof built in memory: the same export the file
/// gets, so the preview carries exactly the file's redaction.
public struct ProofSnapshot: Sendable, Equatable {
    public var range: ProofRange
    public var today: LocalDate
    public var zone: String
    /// `summary.sealed_workdays`.
    public var sealedWorkdays: Int?
    public var countedWorkdays: Int?
    /// Events in range: with their payload or as hashes.
    public var eventsInRange: Int
    /// Every event in the file's chain, genesis to head.
    public var chainEvents: Int
    public var inclusion: ProofInclusion
    /// `summary.plan_done`.
    public var planDone: Int?
    public var planned: Int?
    /// The latest day in range with items, and up to `previewLimit` of them, latest first.
    public var previewDay: LocalDate?
    public var preview: [ProofPreviewItem]
    /// Days in range with a code copied into a stand-up, over days in range that were sealed.
    public var codesCopied: Int
    public var sealedDays: Int
    /// The latest sealed days, up to `codeLimit`, latest first.
    public var codeDays: [ProofCodeDay]
    /// Collectors turned on in config: the only things allowed to reach out.
    public var sources: [String]

    public static let previewLimit = 4
    public static let codeLimit = 4
}

/// The result of Export and check, or of Check a file.
public struct ProofOutcome: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case exported
        case checked
    }

    /// Cadence's own chain, read again after an exported file failed.
    public enum Ledger: Sendable, Equatable {
        case verified(events: Int)
        case failed(String)
    }

    public var action: Action
    public var fileName: String
    public var folderName: String?
    public var passed: Bool
    /// Witness codes in the file, each checkable against a stand-up message.
    public var codes: Int
    public var exportDigest: String?
    /// The first failure, worded for the card, with the event it names.
    public var failure: String?
    public var failingEvent: Int?
    /// Every failure line as the verifier prints it.
    public var fails: [String]
    public var ledger: Ledger?

    /// "SHA-256 9f2c41e0 7ab3d6c1": the digest's first 16 hex characters, in two groups.
    public var digestLine: String? {
        guard let digest = exportDigest, digest.count >= 16 else { return nil }
        let head = digest.prefix(16)
        return "SHA-256 \(head.prefix(8)) \(head.suffix(8))"
    }
}

/// What the section shows while it reads.
public enum ProofLoad: Sendable, Equatable {
    case loading
    case loaded(ProofSnapshot)
    case failed(StoreFailure)
}

/// The Proof section (docs/SPEC.md sections 4.6 and 12): the range, coverage, what the file includes, the preview,
/// Export and check, Check a file, the codes you copied and what leaves this Mac.
///
/// Reads, exports and checks run on a background queue against a fresh read-only connection, so the main thread
/// never waits on the disk and nothing here can write to the ledger. The file goes only where the person chose in
/// the save panel.
@MainActor @Observable
public final class ProofModel {
    public private(set) var preset: ProofPreset = .month
    /// The range Custom uses. Set from the current range when Custom is first picked.
    public private(set) var custom: ProofRange?
    public private(set) var load: ProofLoad = .loading
    public private(set) var outcome: ProofOutcome?
    /// The export or check that is running, if any.
    public private(set) var working: ProofOutcome.Action?

    @ObservationIgnored private let reader: ProofReader
    @ObservationIgnored private let queue = DispatchQueue(label: "in.ashwingopalsamy.cadence.proof-model", qos: .userInitiated)
    @ObservationIgnored private var generation = 0

    public init(reader: ProofReader) {
        self.reader = reader
    }

    /// A model that starts from a read already made, for design sheets that render one state without waiting.
    public init(reader: ProofReader, preset: ProofPreset, load: ProofLoad, outcome: ProofOutcome? = nil) {
        self.reader = reader
        self.preset = preset
        self.load = load
        self.outcome = outcome
    }

    public var snapshot: ProofSnapshot? {
        if case .loaded(let snapshot) = load { return snapshot }
        return nil
    }

    /// The name the save panel suggests.
    public var suggestedFileName: String? { snapshot?.range.fileName }

    public func select(_ preset: ProofPreset) async {
        if preset == .custom, custom == nil { custom = snapshot?.range }
        self.preset = preset
        outcome = nil
        await reload()
    }

    public func setCustom(_ range: ProofRange) async {
        custom = range
        preset = .custom
        outcome = nil
        await reload()
    }

    /// Reads the range again. A newer request wins: an older read that finishes later is dropped.
    public func reload() async {
        generation += 1
        let mine = generation
        let (reader, preset, custom) = (reader, preset, custom)
        let result = await run { reader.load(preset: preset, custom: custom) }
        guard mine == generation else { return }
        load = result
    }

    /// Exports the current range to `url`, then checks the written file with Core's verifier.
    public func export(to url: URL) async {
        guard working == nil, let range = snapshot?.range else { return }
        working = .exported
        let reader = reader
        outcome = await run { reader.export(range, to: url) }
        working = nil
    }

    /// Checks a proof file someone chose.
    public func check(_ url: URL) async {
        guard working == nil else { return }
        working = .checked
        outcome = await run { ProofReader.check(url) }
        working = nil
    }

    public func dismissOutcome() { outcome = nil }

    private func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
