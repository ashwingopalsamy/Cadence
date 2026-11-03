import Foundation

/// Exactly what a collector run executes, before `{since}` and `{until}` are filled in. Its digest is what you approve.
public struct CollectorPlan: Sendable, Equatable {
    public let name: String
    public let executable: String
    /// Every argument after the executable, placeholders still in place.
    public let arguments: [String]
    /// The collector's own environment, on top of the fixed PATH, HOME, LANG and TZ.
    public let env: [String: String]
    /// sha256 of the canonical name, argv and environment. Any change to them asks for approval again.
    public let digest: String

    /// Checks every piece, so what the prompt shows is exactly what runs: an absolute executable, env keys as
    /// `^[A-Z_][A-Z0-9_]*$` and not reserved, and no control, NUL or bidi characters anywhere.
    init(name: String, executable: String, arguments: [String], env: [String: String]) throws(CadenceError) {
        guard Actor.isValidName(name) else { throw .validation("collectors: '\(name)' is not a valid name") }
        guard executable.hasPrefix("/") else { throw .validation("collectors.\(name).command[0]: must be an absolute path") }
        for (index, text) in ([executable] + arguments).enumerated() where !Self.isPlain(text) {
            throw .validation("collectors.\(name).command[\(index)]: must not hold control or bidi characters")
        }
        for key in env.keys.sorted() {
            guard Self.isEnvKey(key) else { throw .validation("collectors.\(name).env.\(key): key must match ^[A-Z_][A-Z0-9_]*$") }
            guard !Config.reservedEnv.contains(key) else { throw .validation("collectors.\(name).env.\(key): is fixed by Cadence") }
            guard Self.isPlain(env[key]!) else { throw .validation("collectors.\(name).env.\(key): must not hold control or bidi characters") }
        }
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.env = env
        var environment: [String: JSONValue] = [:]
        for (key, value) in env { environment[key] = .string(value) }
        let argv = ([executable] + arguments).map { JSONValue.string($0) }
        do {
            digest = SHA256Hasher().sha256Hex(
                try CanonicalJSON.bytes(["name": .string(name), "argv": .array(argv), "env": .object(environment)]))
        } catch {
            throw .validation("collectors.\(name): cannot be written canonically")
        }
    }

    /// The text an approval prompt shows: every argument quoted on its own line, then the environment.
    public var approvalText: String {
        var lines = ["Collector \(name) will run:", "  \(Self.quoted(executable))"]
        lines += arguments.map { "  \(Self.quoted($0))" }
        if env.isEmpty {
            lines.append("with no extra environment.")
        } else {
            lines.append("with this environment:")
            lines += env.keys.sorted().map { "  \($0)=\(Self.quoted(env[$0] ?? ""))" }
        }
        return lines.joined(separator: "\n")
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// No C0 or C1 controls (NUL included), no DEL and no bidi format characters.
    public static func isPlain(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format && (
                (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
                    || scalar.value == 0x200E || scalar.value == 0x200F || scalar.value == 0x061C)
        }
    }

    static func isEnvKey(_ key: String) -> Bool {
        let b = Array(key.utf8)
        let upper: (UInt8) -> Bool = { $0 >= 0x41 && $0 <= 0x5A }
        return !b.isEmpty && (upper(b[0]) || b[0] == 0x5F) && b.allSatisfy { upper($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
    }
}

/// Why a run did not start. Nothing is written for these; `cadence doctor` and the app explain them.
public enum CollectorRefusal: Sendable, Equatable {
    case unknown(String)
    case disabled
    case unsafeConfig(String)
    case notApproved
    case alreadyRunning
    case anotherRunning

    public var message: String {
        switch self {
        case .unknown(let name): "there is no collector named \(name)"
        case .disabled: "the collector is disabled"
        case .unsafeConfig(let why): "collectors are off: \(why)"
        case .notApproved: "the command is new or has changed since you approved it"
        case .alreadyRunning: "a run of this collector is already in progress"
        case .anotherRunning: "another collector is running; runs are one at a time"
        }
    }
}

public enum CollectorRunResult: Sendable, Equatable {
    case ran(IngestReport)
    case refused(CollectorRefusal)
}

/// The dot shows a collector's error state only after three failed runs in a row (docs/SPEC.md section 10.2).
public struct CollectorHealth: Sendable, Equatable {
    public static let failuresBeforeError = 3

    /// Failed runs since the last good one, counted up to three.
    public var failuresInARow: Int
    public var lastError: String?

    public var isFailing: Bool { failuresInARow >= Self.failuresBeforeError }
}

/// Turns a non-envelope output into an envelope, for collectors with a `map` (docs/SPEC.md section 10.5).
public protocol CollectorOutputTransform: Sendable {
    func envelope(from output: [UInt8], collector: Config.Collector, window: IngestWindow) throws(CadenceError) -> MapOutput
}

/// Loads the collector's `map/1` from the maps folder (or an absolute path) and applies it.
public struct MapTransform: CollectorOutputTransform {
    let roots: FileRoots
    let zone: TimeZone
    let boundary: DayBoundary
    let clock: any Clock
    let ids: any IdentifierSource

    public init(roots: FileRoots, zone: TimeZone, boundary: DayBoundary, clock: any Clock, ids: any IdentifierSource) {
        self.roots = roots
        self.zone = zone
        self.boundary = boundary
        self.clock = clock
        self.ids = ids
    }

    public static func location(of map: String, roots: FileRoots) -> URL {
        map.hasPrefix("/") ? URL(fileURLWithPath: map) : roots.maps.appendingPathComponent(map)
    }

    public func envelope(from output: [UInt8], collector: Config.Collector, window: IngestWindow) throws(CadenceError) -> MapOutput {
        guard let mapName = collector.map else { throw .validation("collector \(collector.name) has no map") }
        let url = Self.location(of: mapName, roots: roots)
        // One byte past the cap is read, so a file that is too big is refused without being read whole.
        guard let handle = FileHandle(forReadingAtPath: url.path) else { throw .io("cannot read the map \(url.lastPathComponent)") }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: MapFile.maxBytes + 1) ?? Data()
        } catch {
            throw .io("cannot read the map \(url.lastPathComponent)")
        }
        let map = try MapFile(bytes: Array(data), name: url.deletingPathExtension().lastPathComponent)
        return try MapEngine(map: map, zone: zone, boundary: boundary)
            .envelope(from: output, collector: collector.name, window: window, run: ids.next(), generatedAt: clock.now())
    }
}

/// Runs collectors under the rules of docs/SPEC.md section 10.2: argv only, an absolute path, a fixed environment,
/// limits, approval by digest, a config only you can read, one run per collector at a time.
public struct CollectorRunner {
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin"
    public static let timeout: Duration = .seconds(60)
    public static let killGrace: Duration = .seconds(5)
    public static let stdoutLimit = 10 * 1024 * 1024
    public static let stderrLimit = 64 * 1024
    public static let logLimit = 1024 * 1024

    let roots: FileRoots
    let journal: Journal
    let runner: any ProcessRunner
    /// The cadence binary, which built-in collectors run as a subcommand.
    let selfExecutable: String
    /// The calling process's environment. Only HOME and LANG are read from it.
    let environment: [String: String]
    let transform: (any CollectorOutputTransform)?

    public init(
        roots: FileRoots, journal: Journal, runner: any ProcessRunner, selfExecutable: String,
        environment: [String: String], transform: (any CollectorOutputTransform)? = nil
    ) {
        self.roots = roots
        self.journal = journal
        self.runner = runner
        self.selfExecutable = selfExecutable
        self.environment = environment
        self.transform = transform
    }

    // MARK: - Plans and approval

    /// What a collector runs. Built-ins run this binary's `collector` subcommand.
    public static func plan(for collector: Config.Collector, selfExecutable: String) throws(CadenceError) -> CollectorPlan {
        let since = ["--since", "{since}", "--until", "{until}", "--name", collector.name]
        switch (collector.builtin, collector.command) {
        case ("github"?, nil):
            var args = ["collector", "github"] + since
            if let gh = collector.gh { args += ["--gh", gh] }
            return try CollectorPlan(name: collector.name, executable: selfExecutable, arguments: args, env: collector.env)
        case ("claude-code-transcripts"?, nil):
            return try CollectorPlan(
                name: collector.name, executable: selfExecutable, arguments: ["collector", "claude-code-transcripts"] + since,
                env: collector.env)
        case (nil, let argv?) where !argv.isEmpty:
            return try CollectorPlan(name: collector.name, executable: argv[0], arguments: Array(argv.dropFirst()), env: collector.env)
        default:
            throw .validation("collectors.\(collector.name): needs a known builtin or a command")
        }
    }

    /// Records your approval of exactly this plan.
    public func approve(_ plan: CollectorPlan) throws(CadenceError) {
        var approved = approvals()
        approved[plan.name] = plan.digest
        var object: [String: JSONValue] = [:]
        for (name, digest) in approved { object[name] = .string(digest) }
        let bytes: [UInt8]
        do {
            bytes = try CanonicalJSON.bytes(["approved": .object(object)])
        } catch {
            throw .io("cannot encode the approvals")
        }
        try PrivateFile.save(bytes + [0x0A], to: approvalsFile)
    }

    public func isApproved(_ plan: CollectorPlan) -> Bool {
        approvals()[plan.name] == plan.digest
    }

    var approvalsFile: URL { roots.state.appendingPathComponent("approvals.json") }

    /// Approvals from a file only you can read and write. Anything else counts as no approvals at all.
    private func approvals() -> [String: String] {
        guard let data = PrivateFile.readOwned(approvalsFile),
            let root = try? JSONParser.parse(bytes: data), let object = root.objectValue?["approved"]?.objectValue
        else { return [:] }
        var out: [String: String] = [:]
        for (name, value) in object { if let digest = value.stringValue { out[name] = digest } }
        return out
    }

    // MARK: - Config safety

    /// Nil when the file is yours and nobody else can read or write it; otherwise why not.
    public static func unsafeReason(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return "\(url.lastPathComponent) does not exist" }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return "\(url.lastPathComponent) is not a regular file" }
        guard info.st_uid == getuid() else { return "\(url.lastPathComponent) is not owned by you" }
        guard info.st_mode & 0o077 == 0 else {
            return "\(url.lastPathComponent) has mode \(String(info.st_mode & 0o777, radix: 8)); only you may read or write it (600)"
        }
        return nil
    }

    // MARK: - Running

    /// Runs one collector for `window` and ingests what it printed. A failed command writes only a failed `ingest.run`.
    public func run(name: String, window: IngestWindow) throws(CadenceError) -> CollectorRunResult {
        for edge in [window.since, window.until] where LocalDate(edge) == nil && Timestamp.parse(edge) == nil {
            throw .validation("window: '\(edge)' must be a day or an RFC 3339 time")
        }
        guard let collector = journal.config.collectors.first(where: { $0.name == name }) else { return .refused(.unknown(name)) }
        guard collector.enabled else { return .refused(.disabled) }
        if let why = Self.unsafeReason(roots.config) { return .refused(.unsafeConfig(why)) }
        let plan = try Self.plan(for: collector, selfExecutable: selfExecutable)
        guard isApproved(plan) else { return .refused(.notApproved) }
        guard let lock = try RunLock(roots.state.appendingPathComponent("locks/\(name).lock")) else { return .refused(.alreadyRunning) }
        defer { lock.release() }
        // Runs are serial in v1: one collector at a time across every process.
        guard let serial = try RunLock(roots.state.appendingPathComponent("locks/runs.lock")) else { return .refused(.anotherRunning) }
        defer { serial.release() }

        let request = ProcessRequest(
            executable: plan.executable,
            arguments: plan.arguments.map { Self.fill($0, window) },
            environment: processEnvironment(plan),
            workingDirectory: roots.home, stdin: nil, timeout: Self.timeout, killGrace: Self.killGrace,
            stdoutLimit: Self.stdoutLimit, stderrTailLimit: Self.stderrLimit)
        let result: ProcessResult
        do {
            result = try runner.run(request)
        } catch {
            return .ran(try journal.recordIngestFailure(
                collector: name, window: window, error: "could not start the command: \(Journal.clean(error.localizedDescription, limit: 120))"))
        }
        // Logging is best effort: a log that cannot be written must not hide the run from the ledger.
        try? log(name: name, result: result)

        if let failure = Self.failure(result, name: name) {
            return .ran(try journal.recordIngestFailure(collector: name, window: window, error: failure))
        }
        var output = Array(result.stdout)
        var mapSkipped: [String] = []
        // What a map was applied to. The envelope it made lacks the rows it left out, so the inbox keeps this too.
        var raw: [UInt8]?
        if collector.map != nil {
            guard let transform else {
                return .ran(try journal.recordIngestFailure(collector: name, window: window, error: "map collectors need map/1"))
            }
            raw = output
            do {
                let mapped = try transform.envelope(from: output, collector: collector, window: window)
                output = mapped.envelope
                mapSkipped = mapped.skipped
            } catch {
                return .ran(try journal.recordIngestFailure(
                    collector: name, window: window, error: "map: \(error.message)", inbox: roots.inbox, raw: raw))
            }
        }
        return .ran(try journal.ingest(
            envelope: output, collector: name, window: window, inbox: roots.inbox, skipped: mapSkipped, raw: raw))
    }

    /// `{since}` and `{until}` are replaced inside argv elements, and nowhere else.
    static func fill(_ argument: String, _ window: IngestWindow) -> String {
        argument.replacingOccurrences(of: "{since}", with: window.since).replacingOccurrences(of: "{until}", with: window.until)
    }

    func processEnvironment(_ plan: CollectorPlan) -> [String: String] {
        var env = plan.env
        env["PATH"] = Self.path
        env["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        env["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        env["TZ"] = journal.config.profile.timezone
        return env
    }

    /// Why a finished command counts as failed, or nil when its output should be read. Only the fixed reason goes
    /// to the ledger, which is permanent: stderr can hold a token or a host name, so it stays in `logs/`.
    static func failure(_ result: ProcessResult, name: String) -> String? {
        var why: String?
        if result.timedOut {
            why = "timed out after 60 s"
        } else if case .exited(let status) = result.termination, status != 0 {
            why = "exit status \(status)"
        } else if case .signalled(let signal) = result.termination {
            why = "stopped by signal \(signal)"
        } else if result.stdoutTruncated {
            why = "output was larger than 10 MB and was cut"
        }
        guard let message = why else { return nil }
        return result.stderrTail.isEmpty ? message : "\(message); see logs/collector-\(name).log"
    }

    /// Appends the stderr tail to `logs/collector-<name>.log`, rotating the file at 1 MB.
    private func log(name: String, result: ProcessResult) throws(CadenceError) {
        guard !result.stderrTail.isEmpty else { return }
        let file = roots.logs.appendingPathComponent("collector-\(name).log")
        var existing = Array(FileManager.default.contents(atPath: file.path) ?? Data())
        if existing.count >= Self.logLimit {
            try PrivateFile.save(existing, to: roots.logs.appendingPathComponent("collector-\(name).log.1"))
            existing = []
        }
        let stamp = "--- \(Timestamp.utc(journal.clock.now()))\n"
        var tail = Array(result.stderrTail)
        if tail.last != 0x0A { tail.append(0x0A) }
        try PrivateFile.save(existing + Array(stamp.utf8) + tail, to: file)
    }

    // MARK: - Health

    /// Failed runs in a row for a collector, from its latest `ingest.run` events.
    public func health(name: String) throws(CadenceError) -> CollectorHealth {
        try Self.health(name: name, store: journal.store)
    }

    public static func health(name: String, store: SQLiteStore) throws(CadenceError) -> CollectorHealth {
        let recent: [SQLRow]
        do {
            recent = try store.db.query(
                "SELECT data FROM events WHERE type = 'ingest.run' AND actor = ? ORDER BY seq DESC LIMIT ?",
                [.text(Actor.collector(name).rawValue), .int(Int64(CollectorHealth.failuresBeforeError))])
        } catch {
            throw error.cadenceError
        }
        var failures = 0
        var lastError: String?
        for row in recent {
            guard let text = row.text("data"), let run = try? IngestRun(json: try JSONParser.parse(text)), run.status == "error" else { break }
            if failures == 0 { lastError = run.errors.first }
            failures += 1
        }
        return CollectorHealth(failuresInARow: failures, lastError: lastError)
    }
}

/// An exclusive, non-blocking `flock` on a file, released on `release()` or when the process exits.
final class RunLock {
    private var fd: Int32

    /// Nil when another run holds the lock.
    init?(_ url: URL) throws(CadenceError) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw .io("cannot create \(url.deletingLastPathComponent().lastPathComponent)")
        }
        fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .io("cannot open \(url.lastPathComponent)") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
