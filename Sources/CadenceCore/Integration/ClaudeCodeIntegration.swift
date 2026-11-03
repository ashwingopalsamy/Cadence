import Foundation

/// What Cadence installs into Claude Code and what it expects to find there (docs/SPEC.md sections 9.1, 9.3, 9.4
/// and 10.4). The hooks block and the skill are the files in `integrations/claude-code`, embedded in the binary.
public enum ClaudeCodeIntegration {
    public static let hooksJSON = EmbeddedClaudeCodeFiles.hooksJSON
    public static let skillMarkdown = EmbeddedClaudeCodeFiles.skillMarkdown

    /// The name `claude mcp add` registers the server under.
    public static let mcpName = "cadence"

    /// The least `cleanupPeriodDays` that keeps October's transcripts until they are collected (section 10.4).
    public static let minimumCleanupPeriodDays = 400
    /// What Claude Code uses when `cleanupPeriodDays` is not set (section 10.4).
    public static let defaultCleanupPeriodDays = 30

    /// The launchd label of the collector agent (section 14.3). `CADENCE_AGENT_LABEL` overrides it for a build
    /// made with another `BUNDLE_PREFIX`.
    public static let agentLabel = "in.ashwingopalsamy.cadence.agent"

    /// A spool line that has waited this long means nothing is draining the spool. The spec names no limit.
    public static let spoolWarnAfter: TimeInterval = 24 * 3600

    /// One hook event: Claude Code's name for it and the `cadence hook` argument.
    public struct HookBinding: Sendable, Equatable {
        public let claude: String
        public let cli: HookEventName
    }

    public static let hookEvents: [HookBinding] = [
        HookBinding(claude: "SessionStart", cli: .sessionStart),
        HookBinding(claude: "SessionEnd", cli: .sessionEnd),
        HookBinding(claude: "Stop", cli: .stop),
        HookBinding(claude: "TaskCompleted", cli: .taskCompleted),
    ]

    /// The events of `hooks.json` with their matcher groups, in file order.
    public struct HookBlockEntry: Sendable, Equatable {
        public let event: String
        public let groups: OrderedJSON
    }

    public static func hooksBlock() throws(CadenceError) -> [HookBlockEntry] {
        let document = try OrderedJSON.parse(Array(hooksJSON.utf8))
        guard let members = document["hooks"]?.members else { throw .io("the embedded hooks block has no hooks object") }
        return members.map { HookBlockEntry(event: $0.key, groups: $0.value) }
    }
}

/// Where Claude Code and Cadence keep their files, derived from one user home folder so tests can use a temporary one.
///
/// Claude Code keeps its files in `~/.claude` and its user configuration in `~/.claude.json`. When `CLAUDE_CONFIG_DIR`
/// names a folder, it uses that folder in place of `~/.claude` and keeps the configuration in `<folder>/.claude.json`.
/// Cadence follows the variable only when it is an absolute path; anything else is ignored. The cadence binary and the
/// hooks stay under the user home.
public struct ClaudeCodePaths: Sendable, Equatable {
    public let userHome: URL
    /// The folder `CLAUDE_CONFIG_DIR` names, when it is set to an absolute path.
    public let configDir: URL?

    public init(userHome: URL, configDir: URL? = nil) {
        self.userHome = userHome
        self.configDir = configDir
    }

    /// Follows `CLAUDE_CONFIG_DIR` from `environment`.
    public init(userHome: URL, environment: [String: String]) {
        self.init(userHome: userHome, configDir: Self.configDir(from: environment))
    }

    /// The folder `CLAUDE_CONFIG_DIR` names, when it is an absolute path. Empty, relative and `~` values are not used.
    public static func configDir(from environment: [String: String]) -> URL? {
        guard let value = environment["CLAUDE_CONFIG_DIR"], value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }

    /// True when `CLAUDE_CONFIG_DIR` is set to something that is not an absolute path, so it is not followed.
    public static func ignoresConfigDir(in environment: [String: String]) -> Bool {
        guard let value = environment["CLAUDE_CONFIG_DIR"], !value.isEmpty else { return false }
        return !value.hasPrefix("/")
    }

    public var claudeFolder: URL { configDir ?? userHome.appendingPathComponent(".claude", isDirectory: true) }
    public var settings: URL { claudeFolder.appendingPathComponent("settings.json") }
    public var settingsBackup: URL { claudeFolder.appendingPathComponent("settings.json.cadence-backup") }
    /// Where `claude mcp add --scope user` records servers.
    public var userConfig: URL {
        configDir?.appendingPathComponent(".claude.json") ?? userHome.appendingPathComponent(".claude.json")
    }
    public var skillFolder: URL {
        claudeFolder.appendingPathComponent("skills", isDirectory: true).appendingPathComponent("cadence", isDirectory: true)
    }
    public var skillFile: URL { skillFolder.appendingPathComponent("SKILL.md") }
    public var skillBackup: URL { skillFolder.appendingPathComponent("SKILL.md.cadence-backup") }
    public var cadenceBinary: URL {
        userHome.appendingPathComponent(".local/bin/cadence")
    }
    public func launchAgentPlist(label: String) -> URL {
        userHome.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// A path for people: `~/.claude/settings.json` instead of the full path, when it is under the home folder.
    public func display(_ url: URL) -> String {
        let home = userHome.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }
}

/// A hook command line from `settings.json`, such as `"$HOME/.local/bin/cadence" hook session-start`.
public struct HookCommandLine: Sendable, Equatable {
    /// The program as written, quotes removed.
    public let executable: String
    public let event: String

    /// Reads a command that runs `<path>/cadence hook <event>`. Nil for anything else, so a hook that merely
    /// mentions cadence in an argument does not count.
    public static func parse(_ command: String) -> HookCommandLine? {
        guard let words = ShellWords.split(command), words.count >= 3, words[1] == "hook",
            (words[0] as NSString).lastPathComponent == "cadence"
        else { return nil }
        return HookCommandLine(executable: words[0], event: words[2])
    }

    /// The program's path with `$HOME`, `${HOME}` and a leading `~` filled in. Nil when it is a bare name (found
    /// through PATH) or uses any other variable.
    public func resolvedExecutable(userHome: URL) -> String? {
        var path = executable
        if path.hasPrefix("~/") { path = userHome.path + String(path.dropFirst(1)) }
        path = path.replacingOccurrences(of: "${HOME}", with: userHome.path)
        path = path.replacingOccurrences(of: "$HOME", with: userHome.path)
        guard path.hasPrefix("/"), !path.contains("$") else { return nil }
        return path
    }
}

/// Splits a command line the way a POSIX shell would for the simple cases settings files hold: spaces separate
/// words, single and double quotes group, and a backslash escapes the next character outside single quotes (inside
/// double quotes only a quote or another backslash). Nil when a quote or a backslash is left open.
enum ShellWords {
    static func split(_ text: String) -> [String]? {
        let characters = Array(text)
        var words: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var position = 0
        while position < characters.count {
            let character = characters[position]
            position += 1
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"", position < characters.count,
                    characters[position] == "\"" || characters[position] == "\\"
                {
                    current.append(characters[position])
                    position += 1
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case " ", "\t":
                if started {
                    words.append(current)
                    current = ""
                    started = false
                }
            case "'", "\"":
                quote = character
                started = true
            case "\\":
                guard position < characters.count else { return nil }
                current.append(characters[position])
                position += 1
                started = true
            default:
                current.append(character)
                started = true
            }
        }
        guard quote == nil else { return nil }
        if started { words.append(current) }
        return words
    }
}

/// Reads and writes the JSON files Claude Code owns.
enum ClaudeFiles {
    /// Why a JSON file could not be used.
    enum Problem: Equatable {
        case unreadable(String)
        /// The parser's message, which starts with "not valid JSON".
        case notJSON(String)
        case notAnObject
        /// A symbolic link that leads to no file. `destination` is where it points, nil when it loops.
        case brokenLink(destination: String?)

        /// The phrase that follows the file name: `~/.claude.json is not valid JSON`.
        var phrase: String {
            switch self {
            case .unreadable: "cannot be read"
            case .notJSON: "is not valid JSON"
            case .notAnObject: "does not hold a JSON object"
            case .brokenLink(let destination?): "is a symbolic link to \(destination) that does not lead to a file"
            case .brokenLink(nil): "is a symbolic link that loops"
            }
        }

        /// What setup says when it will not touch the file.
        func refusal(_ display: String) -> CadenceError {
            switch self {
            case .brokenLink:
                return .validation("\(display) \(phrase); point it at a real file or remove it, then run this again")
            case .unreadable(let why): return .io("cannot read \(display): \(why)")
            case .notJSON(let message): return .validation("\(display) is \(message); fix it by hand, then run this again")
            case .notAnObject: return .validation("\(display) does not hold a JSON object; fix it by hand, then run this again")
            }
        }
    }

    /// A symbolic link that leads nowhere: the target is missing or the links loop. Nil for anything else, including a
    /// path that does not exist and a link that works. `FileManager.fileExists` calls such a link missing, and
    /// replacing it would swap the user's link for a regular file.
    static func linkProblem(_ url: URL) -> Problem? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return nil }
        if stat(url.path, &info) == 0 { return nil }
        switch errno {
        case ELOOP: return .brokenLink(destination: nil)
        case ENOENT, ENOTDIR:
            return .brokenLink(destination: try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        default: return .unreadable(String(cString: strerror(errno)))
        }
    }

    enum ReadOutcome {
        case missing
        case loaded(json: OrderedJSON, bytes: [UInt8])
        case failed(Problem)
    }

    /// Reads a file that must hold one JSON object.
    static func read(_ url: URL) -> ReadOutcome {
        if let problem = linkProblem(url) { return .failed(problem) }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let bytes: [UInt8]
        do {
            bytes = Array(try Data(contentsOf: url))
        } catch {
            return .failed(.unreadable(error.localizedDescription))
        }
        let json: OrderedJSON
        do {
            json = try OrderedJSON.parse(bytes)
        } catch {
            return .failed(.notJSON(error.message))
        }
        guard json.members != nil else { return .failed(.notAnObject) }
        return .loaded(json: json, bytes: bytes)
    }

    /// The document, or nil when the file does not exist. A file that is unreadable, not JSON or not an object is an
    /// error that names it and says what to do.
    static func loadObject(_ url: URL, display: String) throws(CadenceError) -> (json: OrderedJSON, bytes: [UInt8])? {
        switch read(url) {
        case .missing: return nil
        case .loaded(let json, let bytes): return (json, bytes)
        case .failed(let problem): throw problem.refusal(display)
        }
    }

    /// Writes `bytes` beside `url` and renames them into place, so a reader never sees half a file.
    static func writeAtomically(
        _ bytes: [UInt8], to url: URL, mode: mode_t, folderMode: mode_t = 0o755
    ) throws(CadenceError) {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: Int(folderMode)])
        } catch {
            throw .io("cannot create \(folder.lastPathComponent)")
        }
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw .io("cannot create a temporary file beside \(url.lastPathComponent)") }
        var ok = fchmod(fd, mode) == 0
        var offset = 0
        while ok && offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0 { ok = false } else { offset += written }
        }
        ok = ok && fsync(fd) == 0
        ok = (close(fd) == 0) && ok
        guard ok, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw .io("cannot write \(url.lastPathComponent)")
        }
    }

    /// Permission bits of the file a path leads to, read with `stat` so a symbolic link is followed and its own mode
    /// (always 0777) is never taken. Nil when the path does not lead to anything.
    static func mode(of url: URL) -> mode_t? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && !isFolder.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

/// The user's MCP registration of `cadence mcp` as `claude mcp add --scope user` records it in `~/.claude.json`.
enum MCPRegistration: Equatable {
    case absent
    /// `command` and `args` as stored.
    case registered(command: String, args: [String])
    /// Registered under the name, but not as a stdio server that has a command.
    case other(String)

    static func read(from config: OrderedJSON) -> MCPRegistration {
        guard let server = config["mcpServers"]?[ClaudeCodeIntegration.mcpName] else { return .absent }
        guard let command = server["command"]?.stringValue else {
            return .other(server["type"]?.stringValue.map { "a \($0) server" } ?? "something that is not a command")
        }
        let args = server["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return .registered(command: command, args: args)
    }

    /// True for a command whose program is called cadence and whose first argument is `mcp`.
    var runsCadenceMCP: Bool {
        guard case .registered(let command, let args) = self else { return false }
        return (command as NSString).lastPathComponent == "cadence" && args.first == "mcp"
    }

    var commandLine: String? {
        guard case .registered(let command, let args) = self else { return nil }
        return ([command] + args).joined(separator: " ")
    }
}

/// Which hook events of a `settings.json` run `cadence hook <event>`.
enum HookStatus {
    /// Events whose hooks include a command that runs cadence for that event.
    static func present(in settings: OrderedJSON) -> Set<String> {
        var found: Set<String> = []
        for binding in ClaudeCodeIntegration.hookEvents {
            if commands(for: binding.claude, in: settings).contains(where: { $0.event == binding.cli.rawValue }) {
                found.insert(binding.claude)
            }
        }
        return found
    }

    /// Every cadence hook command registered for a Claude Code event.
    static func commands(for event: String, in settings: OrderedJSON) -> [HookCommandLine] {
        var out: [HookCommandLine] = []
        for group in settings["hooks"]?[event]?.arrayValue ?? [] {
            for hook in group["hooks"]?.arrayValue ?? [] {
                if let type = hook["type"]?.stringValue, type != "command" { continue }
                if let command = hook["command"]?.stringValue, let parsed = HookCommandLine.parse(command) { out.append(parsed) }
            }
        }
        return out
    }
}
