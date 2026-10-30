import Foundation

/// The built-in Claude Code transcripts collector (docs/SPEC.md section 10.4): reads `<projectsDir>/*/*.jsonl`
/// and writes one `envelope/1` of `genai.usage` records, one per local day and model.
///
/// Each file's per-message facts are cached in the state file, keyed by file path with the file's size and
/// modification time. A file that has not changed is not read again, yet every total is rebuilt from all cached
/// messages, so a day is always complete and a re-run updates the same rows. Cached files stay in the cache after
/// Claude Code deletes them, which keeps the totals of days that are no longer on disk.
public struct TranscriptsCollector: Sendable {
    public struct Output: Sendable, Equatable {
        public var envelope: [UInt8]
        public var filesRead: Int
        public var filesCached: Int
    }

    public let projectsDir: URL
    public let stateFile: URL
    public let zone: TimeZone
    public let boundary: DayBoundary
    public let prices: [String: JSONValue]?

    public init(projectsDir: URL, stateFile: URL, zone: TimeZone, boundary: DayBoundary, prices: [String: JSONValue]?) {
        self.projectsDir = projectsDir
        self.stateFile = stateFile
        self.zone = zone
        self.boundary = boundary
        self.prices = prices
    }

    /// `projectsDir` may start with `~`, which is expanded against `userHome`.
    public init(
        projectsDir: String, userHome: URL, stateFile: URL, zone: TimeZone, boundary: DayBoundary,
        prices: [String: JSONValue]?
    ) {
        self.init(
            projectsDir: URL(
                fileURLWithPath: FileRoots.expandTilde(projectsDir, userHome: userHome), isDirectory: true),
            stateFile: stateFile, zone: zone, boundary: boundary, prices: prices)
    }

    public func run(name: String, runID: String, now: Date, since: LocalDate, until: LocalDate) throws(CadenceError) -> Output {
        let table = try PriceTable(prices)
        var state = TranscriptState.load(from: stateFile)
        var read = 0
        var cached = 0
        var seen: [String] = []
        for file in jsonlFiles() {
            seen.append(file.path)
            if let old = state.files[file.path], old.size == file.size, old.mtime == file.mtime {
                cached += 1
                continue
            }
            guard let messages = Self.readMessages(at: file.url) else {
                if state.files[file.path] != nil { cached += 1 }
                continue
            }
            state.files[file.path] = TranscriptFileState(size: file.size, mtime: file.mtime, messages: messages)
            read += 1
        }
        if read > 0 { try state.save(to: stateFile) }

        let totals = aggregate(state)
        var lines: [String] = []
        lines.append(
            try Self.encode(
                .object([
                    "cadence": .string("envelope/1"), "collector": .string(name), "run": .string(runID),
                    "generated_at": .string(Timestamp.local(now, in: zone)),
                    "window": .object(["since": .string(since.description), "until": .string(until.description)]),
                ])))
        for key in totals.keys.sorted() where key.day >= since && key.day <= until {
            lines.append(try Self.encode(try record(key, totals[key]!, table)))
        }
        return Output(envelope: Array((lines.joined(separator: "\n") + "\n").utf8), filesRead: read, filesCached: cached)
    }

    // MARK: Files

    private struct TranscriptFile {
        var url: URL
        var path: String
        var size: Int64
        var mtime: Int64
    }

    /// `<projectsDir>/*/*.jsonl`, sorted by path so ties between duplicate messages always resolve the same way.
    private func jsonlFiles() -> [TranscriptFile] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(atPath: projectsDir.path) else { return [] }
        var files: [TranscriptFile] = []
        for folder in folders.sorted() {
            let dir = projectsDir.appendingPathComponent(folder, isDirectory: true)
            guard let names = try? manager.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(name)
                guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                    (attributes[.type] as? FileAttributeType) == .typeRegular,
                    let size = (attributes[.size] as? NSNumber)?.int64Value,
                    let modified = attributes[.modificationDate] as? Date
                else { continue }
                files.append(
                    TranscriptFile(
                        url: url, path: url.path, size: size, mtime: Int64((modified.timeIntervalSince1970 * 1000).rounded(.down))))
            }
        }
        return files
    }

    /// Per message id, the line with the most output tokens (the first one on a tie). Nil when the file cannot be read.
    private static func readMessages(at url: URL) -> [String: TranscriptRecord]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var messages: [String: TranscriptRecord] = [:]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            func take(_ end: Int) {
                guard end > start, let line = TranscriptLineScanner.scan(UnsafeBufferPointer(rebasing: bytes[start..<end])) else { return }
                if let kept = messages[line.messageID], kept.o >= line.output { return }
                messages[line.messageID] = TranscriptRecord(line)
            }
            for i in 0..<bytes.count where bytes[i] == 0x0A {
                take(i)
                start = i + 1
            }
            take(bytes.count)
        }
        return messages
    }

    // MARK: Totals

    private struct DayModel: Hashable, Comparable {
        var day: LocalDate
        var model: String
        static func < (a: DayModel, b: DayModel) -> Bool { (a.day, a.model) < (b.day, b.model) }
    }

    private struct Total {
        var sessions: Set<String> = []
        var requests: Int64 = 0
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0
    }

    /// Merges every cached file, deduping by message id across files too (a resumed session repeats history),
    /// then groups by local day and model.
    private func aggregate(_ state: TranscriptState) -> [DayModel: Total] {
        var best: [String: TranscriptRecord] = [:]
        for path in state.files.keys.sorted() {
            for (id, record) in state.files[path]!.messages {
                if let kept = best[id], kept.o >= record.o { continue }
                best[id] = record
            }
        }
        var totals: [DayModel: Total] = [:]
        for record in best.values {
            let day = boundary.day(of: Date(timeIntervalSince1970: Double(record.t)), in: zone)
            let key = DayModel(day: day, model: record.m)
            var total = totals[key] ?? Total()
            if !record.s.isEmpty { total.sessions.insert(record.s) }
            total.requests += 1
            total.input += record.i
            total.output += record.o
            total.cacheRead += record.r
            total.cacheWrite += record.w
            totals[key] = total
        }
        return totals
    }

    private func record(_ key: DayModel, _ total: Total, _ prices: PriceTable) throws(CadenceError) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string("genai.usage"), "source_ref": .string("claude-code:\(key.day):\(key.model)"),
            "day": .string(key.day.description), "tool": .string("claude-code"), "model": .string(key.model),
            "sessions": .int(Int64(total.sessions.count)), "requests": .int(total.requests),
            "tokens": .object([
                "in": .int(total.input), "out": .int(total.output), "cache_read": .int(total.cacheRead),
                "cache_write": .int(total.cacheWrite),
            ]),
        ]
        if let price = prices.price(for: key.model) {
            fields["cost_micros"] = .int(price.cost(total))
            fields["estimated"] = .bool(true)
        }
        return .object(fields)
    }

    private static func encode(_ value: JSONValue) throws(CadenceError) -> String {
        do {
            return try CanonicalJSON.string(value)
        } catch {
            throw .io("cannot encode a usage record: \(error)")
        }
    }

    // MARK: Prices

    /// `config.genai.prices`: model name to `{in, out, cache_read, cache_write}`, each a non-negative integer of
    /// micro-dollars per million tokens. A key left out counts as 0.
    private struct PriceTable {
        struct Price {
            var input: Int64 = 0
            var output: Int64 = 0
            var cacheRead: Int64 = 0
            var cacheWrite: Int64 = 0

            /// Micro-dollars, rounded half up. Int128 keeps the products exact, and the result stops at the largest
            /// integer the envelope accepts.
            fileprivate func cost(_ t: Total) -> Int64 {
                let sum =
                    Int128(t.input) * Int128(input) + Int128(t.output) * Int128(output)
                    + Int128(t.cacheRead) * Int128(cacheRead) + Int128(t.cacheWrite) * Int128(cacheWrite)
                let micros = (sum + 500_000) / 1_000_000
                return Int64(min(micros, Int128(JSONValue.maxSafeInteger)))
            }
        }

        private var prices: [String: Price] = [:]

        init(_ table: [String: JSONValue]?) throws(CadenceError) {
            for (model, value) in table ?? [:] {
                guard case .object(let o) = value else {
                    throw .validation("genai.prices.\(model): must be an object with in, out, cache_read and cache_write")
                }
                var price = Price()
                for (key, raw) in o {
                    guard case .int(let n) = raw, n >= 0 else {
                        throw .validation("genai.prices.\(model).\(key): must be a non-negative integer (micro-dollars per million tokens)")
                    }
                    switch key {
                    case "in": price.input = n
                    case "out": price.output = n
                    case "cache_read": price.cacheRead = n
                    case "cache_write": price.cacheWrite = n
                    default: throw .validation("genai.prices.\(model).\(key): unknown field")
                    }
                }
                prices[model] = price
            }
        }

        func price(for model: String) -> Price? { prices[model] }
    }
}

// MARK: - State

/// One message as cached: the facts the totals need and nothing else.
struct TranscriptRecord: Codable, Sendable, Equatable {
    var t: Int64
    var m: String
    var s: String
    var i: Int64
    var o: Int64
    var r: Int64
    var w: Int64

    init(_ line: TranscriptUsageLine) {
        t = line.timestamp
        m = line.model.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        s = line.sessionID ?? ""
        i = line.input
        o = line.output
        r = line.cacheRead
        w = line.cacheWrite
    }
}

struct TranscriptFileState: Codable, Sendable, Equatable {
    var size: Int64
    /// Milliseconds since the epoch.
    var mtime: Int64
    var messages: [String: TranscriptRecord]
}

/// `state/claude-code-transcripts.json`, written at 0600.
struct TranscriptState: Codable, Sendable, Equatable {
    static let version = 1
    var version = TranscriptState.version
    var files: [String: TranscriptFileState] = [:]

    /// The saved state, or an empty one when the file is missing, unreadable or from another version.
    static func load(from url: URL) -> TranscriptState {
        guard let data = try? Data(contentsOf: url),
            let state = try? JSONDecoder().decode(TranscriptState.self, from: data), state.version == Self.version
        else { return TranscriptState() }
        return state
    }

    func save(to url: URL) throws(CadenceError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { throw .io("cannot encode the transcripts state") }
        try PrivateFile.save(Array(data), to: url)
    }
}
