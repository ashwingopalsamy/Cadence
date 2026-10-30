import Foundation

/// Exactly what a collector run executes, before `{since}` and `{until}` are filled in. Its digest is what you approve.
public struct CollectorPlan: Sendable, Equatable {
    public var name: String
    public var executable: String
    /// Every argument after the executable, placeholders still in place.
    public var arguments: [String]
    /// The collector's own environment, on top of the fixed PATH, HOME, LANG and TZ.
    public var env: [String: String]

    /// sha256 of the canonical argv and environment. Any change to either asks for approval again.
    public var digest: String {
        let argv = ([executable] + arguments).map { JSONValue.string($0) }
        var environment: [String: JSONValue] = [:]
        for (key, value) in env { environment[key] = .string(value) }
        let canonical = (try? CanonicalJSON.bytes(["name": .string(name), "argv": .array(argv), "env": .object(environment)])) ?? []
        return SHA256Hasher().sha256Hex(canonical)
    }

    /// The text an approval prompt shows: every argument on its own line, then the environment.
    public var approvalText: String {
        var lines = ["Collector \(name) will run:", "  \(executable)"]
        lines += arguments.map { "  \($0)" }
        if env.isEmpty {
            lines.append("with no extra environment.")
        } else {
            lines.append("with this environment:")
            lines += env.keys.sorted().map { "  \($0)=\(env[$0] ?? "")" }
        }
        return lines.joined(separator: "\n")
    }
}

/// Why a run did not start. Nothing is written for these; `cadence doctor` and the app explain them.
public enum CollectorRefusal: Sendable, Equatable {
    case unknown(String)
    case disabled
    case unsafeConfig(String)
    case notApproved
    case alreadyRunning

    public var message: String {
        switch self {
        case .unknown(let name): "there is no collector named \(name)"
        case .disabled: "the collector is disabled"
        case .unsafeConfig(let why): "collectors are off: \(why)"
        case .notApproved: "the command is new or has changed since you approved it"
        case .alreadyRunning: "a run of this collector is already in progress"
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
        guard let data = FileManager.default.contents(atPath: url.path) else { throw .io("cannot read the map \(url.lastPathComponent)") }
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
        guard Actor.isValidName(collector.name) else { throw .validation("collectors: '\(collector.name)' is not a valid name") }
        for key in collector.env.keys where Config.reservedEnv.contains(key) {
            throw .validation("collectors.\(collector.name).env.\(key): is fixed by Cadence")
        }
        let since = ["--since", "{since}", "--until", "{until}", "--name", collector.name]
        switch (collector.builtin, collector.command) {
        case ("github"?, nil):
            var args = ["collector", "github"] + since
            if let gh = collector.gh { args += ["--gh", gh] }
            return try checked(CollectorPlan(name: collector.name, executable: selfExecutable, arguments: args, env: collector.env))
        case ("claude-code-transcripts"?, nil):
            return try checked(CollectorPlan(
                name: collector.name, executable: selfExecutable, arguments: ["collector", "claude-code-transcripts"] + since,
                env: collector.env))
        case (nil, let argv?) where !argv.isEmpty:
            return try checked(CollectorPlan(name: collector.name, executable: argv[0], arguments: Array(argv.dropFirst()), env: collector.env))
        default:
            throw .validation("collectors.\(collector.name): needs a known builtin or a command")
        }
    }

    private static func checked(_ plan: CollectorPlan) throws(CadenceError) -> CollectorPlan {
        guard plan.executable.hasPrefix("/") else { throw .validation("collectors.\(plan.name).command[0]: must be an absolute path") }
        return plan
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
        guard Self.unsafeReason(approvalsFile) == nil, let data = FileManager.default.contents(atPath: approvalsFile.path),
            let root = try? JSONParser.parse(bytes: Array(data)), let object = root.objectValue?["approved"]?.objectValue
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
            return "\(url.lastPathComponent) has mode \(String(info.st_mode & 0o777, radix: 8)); it must be 600"
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
            return .ran(try journal.recordIngestFailure(collector: name, window: window, error: "could not start the command"))
        }
        try log(name: name, result: result)

        if let failure = Self.failure(result) {
            return .ran(try journal.recordIngestFailure(collector: name, window: window, error: failure))
        }
        var output = Array(result.stdout)
        var mapSkipped: [String] = []
        if collector.map != nil {
            guard let transform else {
                return .ran(try journal.recordIngestFailure(collector: name, window: window, error: "map collectors need map/1"))
            }
            do {
                let mapped = try transform.envelope(from: output, collector: collector, window: window)
                output = mapped.envelope
                mapSkipped = mapped.skipped
            } catch {
                return .ran(try journal.recordIngestFailure(collector: name, window: window, error: "map: \(error.message)"))
            }
        }
        return .ran(try journal.ingest(envelope: output, collector: name, window: window, inbox: roots.inbox, skipped: mapSkipped))
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

    /// Why a finished command counts as failed, or nil when its output should be read.
    static func failure(_ result: ProcessResult) -> String? {
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
        guard var message = why else { return nil }
        let lastLine = String(decoding: result.stderrTail, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
        if let lastLine {
            let cleaned = Journal.clean(lastLine, limit: 200)
            if !cleaned.isEmpty { message += ": " + cleaned }
        }
        return message
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
        fd = open(url.path, O_RDWR | O_CREAT, 0o600)
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
