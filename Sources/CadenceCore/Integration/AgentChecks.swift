import Foundation

/// Where the code is running, for the checks that only make sense on a Mac.
public enum HostPlatform: Sendable, Equatable {
    case macOS
    case other

    public static var current: HostPlatform {
        #if os(macOS)
            .macOS
        #else
            .other
        #endif
    }
}

/// The `cadence doctor` checks for the Claude Code integration and the collector agent (docs/PLAN.md T2.20):
/// MCP registration, hooks, skill, spool backlog, `cleanupPeriodDays` and the launchd agent.
///
/// These are advice, never failures: a missing integration is a `warn` and does not change doctor's exit code.
/// When a file cannot be read the answer is "unknown", not a guess. Everything is read from the injected home
/// folder; the one command, `launchctl print`, runs only on macOS and only reads.
public struct AgentChecks: Sendable {
    public enum Level: String, Sendable { case ok, warn }

    public struct Result: Sendable, Equatable {
        public let name: String
        public let level: Level
        public let detail: String

        public init(name: String, level: Level, detail: String) {
            self.name = name
            self.level = level
            self.detail = detail
        }
    }

    let paths: ClaudeCodePaths
    let roots: FileRoots
    let clock: any Clock
    let environment: [String: String]
    let runner: any ProcessRunner
    let platform: HostPlatform
    let uid: UInt32

    public init(
        paths: ClaudeCodePaths, roots: FileRoots, clock: any Clock, environment: [String: String],
        runner: any ProcessRunner, platform: HostPlatform, uid: UInt32
    ) {
        self.paths = paths
        self.roots = roots
        self.clock = clock
        self.environment = environment
        self.runner = runner
        self.platform = platform
        self.uid = uid
    }

    public func run() -> [Result] {
        [mcpServer(), hooks(), skill(), spool(), transcriptRetention(), collectorAgent()]
    }

    static let fix = "run cadence setup claude-code --apply"

    private func ok(_ name: String, _ detail: String) -> Result { Result(name: name, level: .ok, detail: detail) }
    private func warn(_ name: String, _ detail: String) -> Result { Result(name: name, level: .warn, detail: detail) }
    private func unknown(_ name: String, _ file: URL, _ problem: ClaudeFiles.Problem) -> Result {
        warn(name, "unknown, \(paths.display(file)) \(problem.phrase)")
    }

    // MARK: mcp server

    func mcpServer() -> Result {
        let name = "mcp server"
        let file = paths.display(paths.userConfig)
        let registration: MCPRegistration
        switch ClaudeFiles.read(paths.userConfig) {
        case .failed(let problem): return unknown(name, paths.userConfig, problem)
        case .missing: registration = .absent
        case .loaded(let json, _): registration = MCPRegistration.read(from: json)
        }
        let unregister = "run claude mcp remove cadence --scope user, then \(Self.fix)"
        switch registration {
        case .absent:
            return warn(name, "not registered; \(Self.fix)")
        case .other(let what):
            return warn(name, "registered, but as \(what) and not cadence mcp; \(unregister)")
        case .registered(let command, _):
            guard registration.runsCadenceMCP else {
                return warn(name, "registered, but it runs \"\(registration.commandLine ?? command)\" and not cadence mcp; \(unregister)")
            }
            let shown = command.hasPrefix("/") ? paths.display(URL(fileURLWithPath: command)) : command
            if command.hasPrefix("/"), !ClaudeFiles.isExecutableFile(command) {
                return warn(name, "registered, but \(shown) is missing or not executable")
            }
            return ok(name, "registered for your user in \(file) and runs \(shown) mcp")
        }
    }

    // MARK: hooks

    func hooks() -> Result {
        let name = "hooks"
        let file = paths.display(paths.settings)
        let settings: OrderedJSON
        switch ClaudeFiles.read(paths.settings) {
        case .failed(let problem): return unknown(name, paths.settings, problem)
        case .missing: return warn(name, "\(file) does not exist; \(Self.fix)")
        case .loaded(let json, _): settings = json
        }
        let present = HookStatus.present(in: settings)
        let missing = ClaudeCodeIntegration.hookEvents.map(\.claude).filter { !present.contains($0) }
        if present.isEmpty { return warn(name, "no cadence hooks in \(file); \(Self.fix)") }
        if !missing.isEmpty {
            let verb = missing.count == 1 ? "does" : "do"
            return warn(name, "\(SetupPlan.list(missing)) \(verb) not run cadence in \(file); \(Self.fix)")
        }
        // Every event is set; the program they run has to exist too. Bare names and other variables cannot be checked.
        var broken: [String] = []
        for binding in ClaudeCodeIntegration.hookEvents {
            for command in HookStatus.commands(for: binding.claude, in: settings) {
                guard let path = command.resolvedExecutable(userHome: paths.userHome), !ClaudeFiles.isExecutableFile(path) else {
                    continue
                }
                if !broken.contains(path) { broken.append(path) }
            }
        }
        if let first = broken.first {
            return warn(name, "all four events are set, but \(paths.display(URL(fileURLWithPath: first))) is missing or not executable")
        }
        return ok(name, "all four events run cadence in \(file)")
    }

    // MARK: skill

    func skill() -> Result {
        let name = "skill"
        let file = paths.display(paths.skillFile)
        guard FileManager.default.fileExists(atPath: paths.skillFile.path) else {
            return warn(name, "not installed; \(Self.fix)")
        }
        guard let current = try? Data(contentsOf: paths.skillFile) else {
            return warn(name, "unknown, \(file) cannot be read")
        }
        if Array(current) == Array(ClaudeCodeIntegration.skillMarkdown.utf8) { return ok(name, "installed at \(file)") }
        return warn(name, "installed at \(file), but it differs from the skill in this cadence; \(Self.fix) to update it")
    }

    // MARK: spool

    func spool() -> Result {
        let name = "spool"
        let backlog = SpoolBacklog.scan(roots: roots)
        guard backlog.stateReadable || backlog.spoolFiles == 0 else {
            let files = backlog.spoolFiles
            return warn(
                name, "unknown, state/spool-drain.json cannot be read; \(files) spool \(files == 1 ? "file is" : "files are") present")
        }
        guard backlog.lines > 0 else { return ok(name, "no hook lines are waiting") }
        let lines = "\(backlog.lines) hook \(backlog.lines == 1 ? "line" : "lines")"
        let files = "\(backlog.files) \(backlog.files == 1 ? "file" : "files")"
        let verb = backlog.lines == 1 ? "is" : "are"
        guard let oldest = backlog.oldest else {
            return warn(name, "\(lines) in \(files) \(verb) waiting and their age is unknown; run cadence spool drain")
        }
        let age = max(0, clock.now().timeIntervalSince(oldest))
        let text = "\(lines) in \(files) \(verb) waiting, the oldest is \(SpoolBacklog.ageText(age)) old"
        if age >= ClaudeCodeIntegration.spoolWarnAfter { return warn(name, text + "; run cadence spool drain") }
        return ok(name, text)
    }

    // MARK: transcript retention

    func transcriptRetention() -> Result {
        let name = "transcript retention"
        let file = paths.display(paths.settings)
        let minimum = ClaudeCodeIntegration.minimumCleanupPeriodDays
        let notSet =
            "cleanupPeriodDays is not set, so Claude Code's default of \(ClaudeCodeIntegration.defaultCleanupPeriodDays) days applies; set it to at least \(minimum) in \(file)"
        let value: OrderedJSON?
        switch ClaudeFiles.read(paths.settings) {
        case .failed(let problem): return unknown(name, paths.settings, problem)
        case .missing: return warn(name, notSet)
        case .loaded(let json, _): value = json["cleanupPeriodDays"]
        }
        guard let value else { return warn(name, notSet) }
        guard case .number(let text) = value, let days = value.doubleValue, days.isFinite else {
            return warn(name, "unknown, cleanupPeriodDays in \(file) is not a number")
        }
        if days >= Double(minimum) { return ok(name, "cleanupPeriodDays is \(text) in \(file)") }
        return warn(
            name,
            "cleanupPeriodDays is \(text), below \(minimum), so Claude Code deletes older transcripts before Cadence collects them; set it to at least \(minimum) in \(file)"
        )
    }

    // MARK: collector agent

    /// The label, unless `CADENCE_AGENT_LABEL` names another one made of letters, digits, dots, dashes and underscores.
    var agentLabel: String {
        if let custom = environment["CADENCE_AGENT_LABEL"], (1...128).contains(custom.utf8.count),
            custom.utf8.allSatisfy({
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E
                    || $0 == 0x2D || $0 == 0x5F
            })
        {
            return custom
        }
        return ClaudeCodeIntegration.agentLabel
    }

    func collectorAgent() -> Result {
        let name = "agent"
        guard platform == .macOS else { return ok(name, "not applicable on this system") }
        let label = agentLabel
        let request = ProcessRequest(
            executable: "/bin/launchctl", arguments: ["print", "gui/\(uid)/\(label)"],
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], workingDirectory: paths.userHome,
            timeout: .seconds(5))
        let result: ProcessResult
        do {
            result = try runner.run(request)
        } catch {
            return warn(name, "unknown, launchctl could not be run")
        }
        if result.timedOut { return warn(name, "unknown, launchctl did not answer in time") }
        if result.succeeded {
            if let code = Self.lastExitCode(result.stdout), code != 0 {
                return warn(name, "loaded, but its last run exited with \(code); see the newest file in logs/")
            }
            return ok(name, "loaded in launchd as \(label)")
        }
        let plist = paths.launchAgentPlist(label: label)
        if FileManager.default.fileExists(atPath: plist.path) {
            return warn(name, "\(paths.display(plist)) exists but launchd has not loaded it")
        }
        return warn(
            name,
            "not loaded; Cadence.app registers it at first launch, and until then collectors run only when you run cadence collect run"
        )
    }

    /// The integer after `last exit code =` in `launchctl print` output, nil for "(never exited)" or no such line.
    static func lastExitCode(_ output: Data) -> Int? {
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("last exit code =") else { continue }
            return Int(trimmed.dropFirst("last exit code =".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
