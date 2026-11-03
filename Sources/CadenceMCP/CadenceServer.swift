import CadenceCore
import Foundation

extension CadenceMCP {
    public static let serverName = "cadence"

    /// Sent in `initialize` and `server/discover`: how a model should use the tools, in a few lines.
    public static let instructions = """
        Cadence is the user's local work log. Log one finished outcome with log_entry: one line, past tense, in the \
        user's words, with the ticket key if one is in play. Do not log routine tool calls, and never invent times, \
        tickets or counts; if the date is unclear, ask. For a pasted transcript call log_entries with dry_run true, \
        show the user the preview, and call again with dry_run false only after they agree. Entries for past days \
        and everything from log_entries wait in the user's Inbox as proposals. Accepting, sealing, deleting and \
        presence belong to the user, and no tool does them.
        """

    /// The server `cadence mcp` runs: the nine tools, two resources and three prompts, over a journal made fresh
    /// for each call. `readJournal` serves the reads and dry runs; it must not start the ledger. Without one, `journal`
    /// serves every call.
    public static func server(
        journal: @escaping JournalProvider, readJournal: JournalProvider? = nil, clock: any Clock, version: String,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws(CadenceError) -> MCPServer {
        let reading = readJournal ?? journal
        return try MCPServer(
            name: serverName, version: version, instructions: instructions, tools: tools(journal: journal, readJournal: reading),
            resources: resources(journal: reading), prompts: prompts(), clock: clock, log: log)
    }
}
