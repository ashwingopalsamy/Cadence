import ArgumentParser
import CadenceCore
import Foundation

/// `cadence hook <event>`: Claude Code's hook entry point (docs/SPEC.md section 9.3). It never fails the
/// caller: whatever goes wrong, it exits 0, prints at most one line to stderr and nothing to stdout.
/// The spool path never opens the store; only SessionStart reads it, read-only, after the spool write.
struct HookCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook", abstract: "Record a Claude Code hook call (reads the hook JSON on stdin).")

    @Argument(help: "session-start, session-end, stop or task-completed.") var event: String

    func run() throws {
        let context = CLIContext.current()
        let input = [UInt8](FileHandle.standardInput.readDataToEndOfFile())
        let clock = context.clock
        let roots = context.roots
        let result = HookRunner.run(
            event: event, input: input, spool: roots.spool, now: clock.now(),
            plan: { HookPlan.contextLine(roots: roots, clock: clock) })
        if let text = result.stdout { writeLine(text, to: FileHandle.standardOutput) }
        if let warning = result.warning { writeLine("cadence hook: \(warning)", to: FileHandle.standardError) }
    }
}
