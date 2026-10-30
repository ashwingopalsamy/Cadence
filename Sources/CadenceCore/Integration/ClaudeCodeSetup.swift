import Foundation

/// What `cadence setup claude-code` would do, worked out from the files on disk and nothing else. Building a plan
/// writes nothing and runs nothing, so `--print` is exactly the plan and `--apply` runs the same plan.
public struct SetupPlan: Sendable {
    public struct Hooks: Sendable {
        public enum Action: String, Sendable { case create, merge, none }
        public var action: Action
        public var file: URL
        /// Events that get a cadence hook, in the order of `hooks.json`.
        public var added: [String]
        /// Events that already run cadence and are left as they are.
        public var present: [String]
        /// Where the current file is saved first. Nil when there is no file to save.
        public var backup: URL?
        /// The `{"hooks": {...}}` fragment that is merged in.
        public var block: OrderedJSON
        var originalBytes: [UInt8]?
        var updatedBytes: [UInt8]?
    }

    public struct MCP: Sendable {
        public enum Action: Equatable, Sendable {
            case register
            case alreadyRegistered
            /// Registered under the name with another command, shown as the command line.
            case differs(String)
            /// `claude` is not on PATH.
            case unavailable
        }
        public var action: Action
        /// The absolute path of `claude`, when it was found.
        public var claude: String?
        /// The arguments after `claude`, with the home folder expanded.
        public var arguments: [String]
    }

    public struct Skill: Sendable {
        public enum Action: String, Sendable { case create, replace, none }
        public var action: Action
        public var file: URL
        public var backup: URL?
    }

    public var paths: ClaudeCodePaths
    public var hooks: Hooks
    public var mcp: MCP
    public var skill: Skill
    public var notes: [String]

    public var changesAnything: Bool {
        hooks.action != .none || skill.action != .none || mcp.action == .register
    }
}

/// What happened to the MCP registration when the plan was applied.
public enum MCPOutcome: Equatable, Sendable {
    case registered
    /// Nothing to do, or a registration that was left alone.
    case unchanged
    case skipped(String)
}

public struct SetupResult: Sendable {
    public var plan: SetupPlan
    public var mcp: MCPOutcome
}

/// `cadence setup claude-code` (docs/SPEC.md sections 9.1 and 14.5): merge the hooks into
/// `~/.claude/settings.json`, register `cadence mcp` with Claude Code and copy the skill.
///
/// Nothing here touches the network. The registration is the one command the spec names,
/// `claude mcp add --scope user`, which only edits Claude Code's own configuration. It runs through a
/// `ProcessRunner` with an absolute path found on PATH and a small fixed environment.
public struct ClaudeCodeSetup: Sendable {
    public let paths: ClaudeCodePaths
    let environment: [String: String]
    let runner: any ProcessRunner

    /// `environment` supplies PATH for finding `claude` and `CLAUDE_CONFIG_DIR` for Claude Code's folder, when it is
    /// an absolute path. `userHome` is the only home folder ever used.
    public init(userHome: URL, environment: [String: String], runner: any ProcessRunner) {
        self.paths = ClaudeCodePaths(userHome: userHome, environment: environment)
        self.environment = environment
        self.runner = runner
    }

    // MARK: plan

    public func plan() throws(CadenceError) -> SetupPlan {
        var notes: [String] = []
        if !ClaudeFiles.isExecutableFile(paths.cadenceBinary.path) {
            notes.append(
                "\(paths.display(paths.cadenceBinary)) is not installed yet, so the hooks and the MCP server cannot run until it is; run make install or copy the cadence binary there"
            )
        }
        if ClaudeCodePaths.ignoresConfigDir(in: environment) {
            notes.append("CLAUDE_CONFIG_DIR is not an absolute path, so \(paths.display(paths.claudeFolder)) is used")
        }
        return SetupPlan(
            paths: paths, hooks: try planHooks(), mcp: planMCP(), skill: try planSkill(), notes: notes)
    }

    func planHooks() throws(CadenceError) -> SetupPlan.Hooks {
        let display = paths.display(paths.settings)
        let loaded = try ClaudeFiles.loadObject(paths.settings, display: display)
        var settings = loaded?.json ?? .object([])
        var hooksObject = OrderedJSON.object([])
        if let existing = settings["hooks"] {
            guard existing.members != nil else {
                throw .validation("hooks in \(display) is not an object; fix it by hand, then run this again")
            }
            hooksObject = existing
        }
        let alreadyThere = HookStatus.present(in: settings)
        var added: [String] = []
        var present: [String] = []
        var fragment: [OrderedJSON.Member] = []
        for entry in try ClaudeCodeIntegration.hooksBlock() {
            if alreadyThere.contains(entry.event) {
                present.append(entry.event)
                continue
            }
            switch hooksObject[entry.event] {
            case nil:
                hooksObject.setMember(entry.event, entry.groups)
            case .array(let groups)?:
                hooksObject.setMember(entry.event, .array(groups + (entry.groups.arrayValue ?? [])))
            default:
                throw .validation(
                    "hooks.\(entry.event) in \(display) is not a list; fix it by hand, then run this again")
            }
            added.append(entry.event)
            fragment.append(OrderedJSON.Member(entry.event, entry.groups))
        }
        let block = OrderedJSON.object([OrderedJSON.Member("hooks", .object(fragment))])
        guard !added.isEmpty else {
            return SetupPlan.Hooks(
                action: .none, file: paths.settings, added: [], present: present, backup: nil, block: block)
        }
        settings.setMember("hooks", hooksObject)
        var text = settings.serialized()
        // Keep the file's own ending; a new file gets a final newline.
        if loaded == nil || loaded?.bytes.last == 0x0A { text += "\n" }
        return SetupPlan.Hooks(
            action: loaded == nil ? .create : .merge, file: paths.settings, added: added, present: present,
            backup: loaded == nil ? nil : paths.settingsBackup, block: block, originalBytes: loaded?.bytes,
            updatedBytes: Array(text.utf8))
    }

    func planMCP() -> SetupPlan.MCP {
        let arguments = [
            "mcp", "add", "--transport", "stdio", "--scope", "user", ClaudeCodeIntegration.mcpName, "--",
            paths.cadenceBinary.path, "mcp",
        ]
        let claude = findClaude()
        // A config Cadence cannot read is not an error here: `claude` owns the file and will say so.
        let config = (try? ClaudeFiles.loadObject(paths.userConfig, display: paths.display(paths.userConfig)))?.json
        let registration = config.map(MCPRegistration.read(from:)) ?? .absent
        let action: SetupPlan.MCP.Action
        switch registration {
        case .absent: action = claude == nil ? .unavailable : .register
        case .registered where registration.runsCadenceMCP: action = .alreadyRegistered
        case .registered: action = .differs(registration.commandLine ?? "")
        case .other(let what): action = .differs(what)
        }
        return SetupPlan.MCP(action: action, claude: claude, arguments: arguments)
    }

    func planSkill() throws(CadenceError) -> SetupPlan.Skill {
        let wanted = Array(ClaudeCodeIntegration.skillMarkdown.utf8)
        // A link that leads nowhere is the user's; it is not replaced by a regular file. A working one is followed.
        if let problem = ClaudeFiles.linkProblem(paths.skillFile) { throw problem.refusal(paths.display(paths.skillFile)) }
        guard FileManager.default.fileExists(atPath: paths.skillFile.path) else {
            return SetupPlan.Skill(action: .create, file: paths.skillFile, backup: nil)
        }
        guard let current = try? Data(contentsOf: paths.skillFile) else {
            throw .io("cannot read \(paths.display(paths.skillFile))")
        }
        if Array(current) == wanted { return SetupPlan.Skill(action: .none, file: paths.skillFile, backup: nil) }
        return SetupPlan.Skill(action: .replace, file: paths.skillFile, backup: paths.skillBackup)
    }

    /// The absolute entries of PATH, in order. A relative entry depends on the folder the command runs in, so it is
    /// neither searched for `claude` nor handed on to it.
    var absolutePathEntries: [String] {
        (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("/") }.map(String.init)
    }

    /// The first executable file called `claude` in an absolute PATH entry.
    func findClaude() -> String? {
        for entry in absolutePathEntries {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true).appendingPathComponent("claude").path
            if ClaudeFiles.isExecutableFile(candidate) { return candidate }
        }
        return nil
    }

    // MARK: apply

    /// Plans again from what is on disk now, then does what the plan says: hooks, skill, then the registration.
    /// Running it twice changes nothing the second time.
    public func apply() throws(CadenceError) -> SetupResult {
        let plan = try self.plan()
        if plan.hooks.action != .none || plan.skill.action != .none {
            // A new ~/.claude is private, as Claude Code makes it.
            do {
                try FileManager.default.createDirectory(
                    at: paths.claudeFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw .io("cannot create \(paths.display(paths.claudeFolder))")
            }
        }
        try applyHooks(plan.hooks)
        try applySkill(plan.skill)
        let outcome: MCPOutcome
        do {
            outcome = try applyMCP(plan.mcp)
        } catch {
            throw CadenceError.io(error.message + "; the hooks and the skill are already in place")
        }
        return SetupResult(plan: plan, mcp: outcome)
    }

    private func applyHooks(_ hooks: SetupPlan.Hooks) throws(CadenceError) {
        guard hooks.action != .none, let updated = hooks.updatedBytes else { return }
        // The backup goes first, so a failure after it still leaves the original recoverable.
        if let original = hooks.originalBytes, let backup = hooks.backup {
            try ClaudeFiles.writeAtomically(original, to: backup, mode: 0o600, folderMode: 0o700)
        }
        // A settings file that is a symlink (for example into a dotfiles repo) stays one: the target is replaced.
        let target = paths.settings.resolvingSymlinksInPath()
        try ClaudeFiles.writeAtomically(
            updated, to: target, mode: ClaudeFiles.mode(of: target) ?? 0o600, folderMode: 0o700)
    }

    private func applySkill(_ skill: SetupPlan.Skill) throws(CadenceError) {
        guard skill.action != .none else { return }
        let target = paths.skillFile.resolvingSymlinksInPath()
        if skill.action == .replace, let backup = skill.backup {
            guard let current = try? Data(contentsOf: target) else { throw .io("cannot read \(paths.display(target))") }
            try ClaudeFiles.writeAtomically(Array(current), to: backup, mode: 0o600)
        }
        try ClaudeFiles.writeAtomically(Array(ClaudeCodeIntegration.skillMarkdown.utf8), to: target, mode: 0o644)
    }

    private func applyMCP(_ mcp: SetupPlan.MCP) throws(CadenceError) -> MCPOutcome {
        switch mcp.action {
        case .alreadyRegistered, .differs: return .unchanged
        case .unavailable: return .skipped("claude is not on your PATH")
        case .register:
            guard let claude = mcp.claude else { return .skipped("claude is not on your PATH") }
            let entries = absolutePathEntries
            var childEnvironment: [String: String] = [
                "HOME": paths.userHome.path, "PATH": entries.isEmpty ? "/usr/bin:/bin" : entries.joined(separator: ":"),
                "LANG": environment["LANG"] ?? "en_US.UTF-8",
                // `claude mcp add` only edits configuration; these ask it to stay offline anyway.
                "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            ]
            if let tmp = environment["TMPDIR"] { childEnvironment["TMPDIR"] = tmp }
            // Tell claude the folder setup reads, so it records the registration where doctor looks for it.
            if let folder = paths.configDir { childEnvironment["CLAUDE_CONFIG_DIR"] = folder.path }
            let request = ProcessRequest(
                executable: claude, arguments: mcp.arguments, environment: childEnvironment,
                workingDirectory: paths.userHome, timeout: .seconds(30))
            let result: ProcessResult
            do {
                result = try runner.run(request)
            } catch {
                let reason = (error as? CadenceError)?.message ?? "\(error)"
                throw .io("claude mcp add failed: \(reason)")
            }
            if result.timedOut { throw .io("claude mcp add timed out after 30 seconds") }
            guard result.succeeded else {
                var code = "did not finish"
                switch result.termination {
                case .exited(let status): code = "exit \(status)"
                case .signalled(let signal): code = "signal \(signal)"
                }
                let line = Self.firstLine(result.stderrTail)
                throw .io("claude mcp add failed (\(code))" + (line.isEmpty ? "" : ": " + line))
            }
            return .registered
        }
    }

    /// The first non-empty line of command output, without control characters, cut to 200 characters.
    static func firstLine(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let clean = String(String.UnicodeScalarView(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        return String(clean.prefix(200))
    }
}

// MARK: - what people and scripts read

extension SetupPlan {
    /// The `--print` text: finding first, one block per part, and nothing changed.
    public var human: String {
        Self.render(plan: self, outcome: nil)
    }

    /// The `--print --json` object.
    public var json: JSONValue { Self.renderJSON(plan: self, outcome: nil) }

    static let registerCommand =
        #"claude mcp add --transport stdio --scope user cadence -- "$HOME/.local/bin/cadence" mcp"#

    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// `outcome` is nil for a plan that was not run.
    static func render(plan: SetupPlan, outcome: MCPOutcome?) -> String {
        let applied = outcome != nil
        let paths = plan.paths
        var lines: [String] = []
        if !plan.changesAnything {
            lines.append("Nothing to change.")
            lines.append("")
        } else if !applied {
            lines.append("Nothing was changed. Run cadence setup claude-code --apply to make these changes.")
            lines.append("")
        }

        // hooks
        let settings = paths.display(paths.settings)
        let hooks = plan.hooks
        switch hooks.action {
        case .none:
            lines.append("hooks: nothing to change, all four events already run cadence in \(settings)")
        case .create, .merge:
            lines.append("hooks: \(applied ? "added" : "add") \(list(hooks.added)) to \(settings)")
            if hooks.action == .create {
                lines.append("  The file \(applied ? "did not exist, so cadence created it" : "does not exist yet, so cadence creates it").")
            }
            if !hooks.present.isEmpty { lines.append("  Already there and left as they are: \(list(hooks.present)).") }
            if let backup = hooks.backup {
                lines.append(
                    "  Your other settings and hooks stay as they are. "
                        + (applied
                            ? "The previous file is saved as \(paths.display(backup)), mode 0600."
                            : "The current file is saved first as \(paths.display(backup)), mode 0600."))
            }
            if !applied {
                lines.append("  Added to the hooks object:")
                for line in hooks.block.serialized().split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("    " + line)
                }
            }
        }

        lines.append("")

        // mcp
        switch plan.mcp.action {
        case .alreadyRegistered:
            lines.append("mcp server: nothing to change, cadence is already registered with Claude Code")
        case .differs(let what):
            lines.append("mcp server: left alone, cadence is already registered as \"\(what)\"")
            lines.append(
                "  To replace it, run claude mcp remove cadence --scope user, then cadence setup claude-code --apply.")
        case .unavailable:
            lines.append("mcp server: skipped, claude is not on your PATH")
            lines.append("  Install Claude Code, then run: \(registerCommand)")
        case .register:
            lines.append(
                "mcp server: \(applied ? "registered" : "register") cadence with Claude Code for your user")
            if !applied {
                lines.append("  \(registerCommand)")
                lines.append("  claude is at \(plan.mcp.claude ?? "").")
            }
        }

        lines.append("")

        // skill
        let skill = paths.display(plan.skill.file)
        switch plan.skill.action {
        case .none:
            lines.append("skill: nothing to change, \(skill) is up to date")
        case .create:
            lines.append("skill: \(applied ? "copied" : "copy") the cadence skill to \(skill)")
        case .replace:
            lines.append("skill: \(applied ? "replaced" : "replace") \(skill) with the skill in this cadence")
            if let backup = plan.skill.backup {
                lines.append(
                    "  \(applied ? "The previous file is saved as" : "The current file is saved first as") \(paths.display(backup)), mode 0600."
                )
            }
        }

        if !plan.notes.isEmpty { lines.append("") }
        for note in plan.notes { lines.append("note: \(note)") }
        if applied && plan.changesAnything {
            lines.append("")
            lines.append("Start a new Claude Code session, run /mcp to check that cadence is connected, then run cadence doctor.")
        }
        return lines.joined(separator: "\n")
    }

    static func renderJSON(plan: SetupPlan, outcome: MCPOutcome?) -> JSONValue {
        func path(_ url: URL?) -> JSONValue { url.map { .string($0.path) } ?? .null }
        func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }
        let mcpAction: String
        switch plan.mcp.action {
        case .register: mcpAction = "register"
        case .alreadyRegistered: mcpAction = "already_registered"
        case .differs: mcpAction = "differs"
        case .unavailable: mcpAction = "unavailable"
        }
        var mcp: [String: JSONValue] = [
            "action": .string(mcpAction), "claude": plan.mcp.claude.map { .string($0) } ?? .null,
            "command": strings(plan.mcp.claude.map { [$0] + plan.mcp.arguments } ?? []),
        ]
        var changed = false
        if let outcome {
            switch outcome {
            case .registered:
                mcp["outcome"] = "registered"
                changed = true
            case .unchanged: mcp["outcome"] = "unchanged"
            case .skipped(let why):
                mcp["outcome"] = "skipped"
                mcp["reason"] = .string(why)
            }
            changed = changed || plan.hooks.action != .none || plan.skill.action != .none
        }
        return [
            "mode": .string(outcome == nil ? "print" : "apply"), "changed": .bool(changed),
            "hooks": [
                "file": path(plan.hooks.file), "action": .string(plan.hooks.action.rawValue),
                "add": strings(plan.hooks.added), "present": strings(plan.hooks.present), "backup": path(plan.hooks.backup),
            ],
            "mcp": .object(mcp),
            "skill": [
                "file": path(plan.skill.file), "action": .string(plan.skill.action.rawValue), "backup": path(plan.skill.backup),
            ],
            "notes": strings(plan.notes),
        ]
    }
}

extension SetupResult {
    public var human: String { SetupPlan.render(plan: plan, outcome: mcp) }
    public var json: JSONValue { SetupPlan.renderJSON(plan: plan, outcome: mcp) }
}
