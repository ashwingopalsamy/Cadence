import ArgumentParser
import CadenceCore
import CadenceMCP
import Foundation

/// `cadence mcp`: the MCP server on stdin and stdout (docs/SPEC.md section 9.2). Claude Code starts it. It logs
/// only to stderr, never an entry title, and every write is recorded with actor `mcp` and origin `agent`.
/// The store is opened for each tool call, so a busy or newer store is a readable tool error and not a crash.
struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp", abstract: "Run the MCP server on stdin and stdout (Claude Code starts this).")

    func run() throws {
        let context = CLIContext.current()
        let server: MCPServer
        do {
            server = try CadenceMCP.server(
                journal: { () throws(CadenceError) -> Journal in try context.openJournal(actor: .mcp) }, clock: context.clock,
                version: CadenceVersion.app,
                log: { writeLine("cadence mcp: \($0)", to: FileHandle.standardError) })
        } catch {
            throw fail(error)
        }
        server.serve(input: FileHandle.standardInput, output: FileHandle.standardOutput)
    }
}
