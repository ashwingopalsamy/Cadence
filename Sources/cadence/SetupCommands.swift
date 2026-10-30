import ArgumentParser
import CadenceCore
import Foundation

/// `cadence setup <integration>`: one-time wiring of Cadence into another tool (docs/SPEC.md sections 9.1 and 14.5).
struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup", abstract: "Set up Cadence for another tool.", subcommands: [ClaudeCodeSetupCommand.self])
}

/// `cadence setup claude-code --print|--apply`: merge the hooks into `~/.claude/settings.json`, register
/// `cadence mcp` and copy the skill. `--print` shows exactly what `--apply` would do and changes nothing.
/// Neither touches the network; the registration is `claude mcp add --scope user`, which edits Claude Code's own
/// configuration.
struct ClaudeCodeSetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude-code",
        abstract: "Merge the hooks, register the MCP server and copy the skill for Claude Code.",
        discussion: """
            Choose one of --print and --apply. --apply saves ~/.claude/settings.json as \
            ~/.claude/settings.json.cadence-backup (mode 0600) before it changes it, keeps your other settings and \
            hooks, and does nothing a second time. The MCP registration runs claude mcp add and is skipped, with a \
            message, when claude is not on your PATH.
            """)

    @Flag(name: .customLong("print"), help: "Show what --apply would change and change nothing.") var printOnly = false
    @Flag(name: .customLong("apply"), help: "Make the changes.") var apply = false
    @OptionGroup var output: OutputOptions

    func run() throws {
        try output.run { context in
            guard printOnly != apply else {
                throw CadenceError.usage("choose one of --print and --apply; --print changes nothing")
            }
            let setup = ClaudeCodeSetup(
                userHome: context.userHome, environment: context.environment, runner: SystemProcessRunner())
            if apply {
                let result = try setup.apply()
                return Rendered(human: result.human, json: result.json)
            }
            let plan = try setup.plan()
            return Rendered(human: plan.human, json: plan.json)
        }
    }
}
