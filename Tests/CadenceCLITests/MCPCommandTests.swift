import CadenceCore
import Foundation
import Testing

/// `cadence mcp` run as Claude Code runs it: JSON-RPC lines on stdin, JSON-RPC lines on stdout, a temp CADENCE_HOME.
@Suite struct MCPCommandTests {
    static let meta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]

    /// One request line; the stateless revision needs no handshake.
    static func request(_ id: Int, _ method: String, _ params: JSONValue = [:]) throws -> String {
        var object = params.objectValue ?? [:]
        object["_meta"] = meta
        return try CanonicalJSON.string(["jsonrpc": "2.0", "id": .int(Int64(id)), "method": .string(method), "params": .object(object)])
    }

    static func call(_ id: Int, _ tool: String, _ arguments: JSONValue = [:]) throws -> String {
        try request(id, "tools/call", ["name": .string(tool), "arguments": arguments])
    }

    /// Runs the server on `lines` and returns the parsed reply lines, keyed by id.
    func serve(_ home: CLIHome, _ lines: [String]) throws -> (replies: [Int64: JSONValue], run: CLIRun) {
        let run = try home.run(["mcp"], stdin: lines.joined(separator: "\n") + "\n")
        var replies: [Int64: JSONValue] = [:]
        for line in run.stdout.split(separator: "\n") {
            let reply = try JSONParser.parse(String(line))
            #expect(reply["jsonrpc"] == "2.0", "stdout carries only JSON-RPC: \(line)")
            if let id = reply["id"]?.intValue { replies[id] = reply }
        }
        return (replies, run)
    }

    func text(_ reply: JSONValue?) -> String { reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "" }

    @Test func theServerSpeaksBothRevisionsOverPipes() throws {
        let home = CLIHome()
        defer { home.remove() }
        let session = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ]
        let (replies, run) = try serve(home, session + [try Self.request(3, "server/discover"), try Self.request(4, "tools/list")])
        #expect(run.status == 0)
        #expect(replies[1]?["result"]?["protocolVersion"] == "2025-11-25")
        #expect(replies[1]?["result"]?["serverInfo"]?["name"] == "cadence")
        let names = replies[2]?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["log_entry", "log_entries", "plan_add", "plan_update", "declare_day", "get_day", "query", "summary", "standup"])
        #expect(replies[3]?["result"]?["supportedVersions"] == ["2026-07-28", "2025-11-25"])
        #expect(replies[4]?["result"]?["resultType"] == "complete")
        #expect(run.stderr.isEmpty)
    }

    @Test func aLoggedLineLandsInTheRealStoreAsAgentWrittenByMcp() throws {
        let home = CLIHome()
        defer { home.remove() }
        let title = "Fixed flaky ledger test with deterministic clock"
        let yesterday = try home.today().adding(days: -1)
        let (replies, run) = try serve(
            home,
            [
                try Self.call(1, "log_entry", ["text": .string(title), "ticket": "ACME-482913"]),
                try Self.call(2, "log_entry", ["text": "Paired on the capture path", "date": .string(yesterday.description)]),
                try Self.call(3, "get_day"),
            ])
        #expect(run.status == 0)
        #expect(text(replies[1]).hasPrefix("Logged for "))
        #expect(replies[1]?["result"]?["structuredContent"]?["status"] == "accepted")
        #expect(replies[2]?["result"]?["structuredContent"]?["status"] == "proposed")
        #expect(text(replies[3]).contains(title))
        // Entry titles never reach stderr.
        #expect(!run.stderr.contains("flaky") && !run.stderr.contains("Paired"))

        // The CLI sees both, with origin agent.
        let queried = try home.json(["query", "--origin", "agent", "--from", yesterday.description])
        let entries = try #require(queried["entries"]?.arrayValue)
        #expect(entries.count == 2 && entries.allSatisfy { $0["origin"] == "agent" })
        #expect(entries.map { $0["status"] } == ["proposed", "accepted"])
        let ledger = try home.journal()
        let first = try #require(entries.first?["id"]?.stringValue)
        let events = try ledger.history(subject: "entry:\(first)")
        #expect(events.map(\.type) == ["entry.created"] && events.map(\.actor) == [.mcp])

        // The user accepts the proposal; accepting never changes who wrote it.
        let inbox = try home.json(["inbox", "list"])
        #expect(inbox["entries"]?.arrayValue?.map { $0["id"] } == [.string(first)])
        let accepted = try home.json(["inbox", "accept", first])
        #expect(accepted["entry"]?["status"] == "accepted" && accepted["entry"]?["origin"] == "agent")
    }

    @Test func dictationGoesThroughAPreviewThenToTheInbox() throws {
        let home = CLIHome()
        defer { home.remove() }
        let day = try home.today().adding(days: -1)
        let transcript = "- Reviewed settlement batching RFC ACME-482913\n- Paired on the flaky ledger test ~1h"
        let arguments: JSONValue = ["transcript": .string(transcript), "date": .string(day.description)]
        var real = arguments.objectValue ?? [:]
        real["dry_run"] = false
        let (replies, run) = try serve(
            home, [try Self.call(1, "log_entries", arguments), try Self.call(2, "query", ["from": .string(day.description)]),
                   try Self.call(3, "log_entries", .object(real)), try Self.call(4, "query", ["from": .string(day.description)])])
        #expect(run.status == 0)
        #expect(replies[1]?["result"]?["structuredContent"]?["status"] == "preview")
        #expect(replies[2]?["result"]?["structuredContent"]?["count"] == 0)
        #expect(replies[3]?["result"]?["structuredContent"]?["status"] == "proposed")
        #expect(replies[4]?["result"]?["structuredContent"]?["count"] == 2)
        let inbox = try home.json(["inbox", "list"])
        #expect(inbox["entries"]?.arrayValue?.count == 2)
        #expect(inbox["entries"]?.arrayValue?.allSatisfy { $0["origin"] == "agent" && $0["attrs"]?["dictated"] == true } == true)
    }

    @Test func aStoreThatCannotBeOpenedIsAToolErrorAndTheServerKeepsGoing() throws {
        let home = CLIHome()
        defer { home.remove() }
        try FileManager.default.createDirectory(atPath: home.database, withIntermediateDirectories: true)
        let (replies, run) = try serve(home, [try Self.call(1, "get_day"), try Self.request(2, "ping")])
        #expect(run.status == 0)
        #expect(replies[1]?["error"] == nil && replies[1]?["result"]?["isError"] == true)
        #expect(text(replies[1]).hasPrefix("Not done: "))
        #expect(replies[2]?["result"]?["resultType"] == "complete")
    }

    @Test func badLinesGetErrorsAndStdoutStaysJSON() throws {
        let home = CLIHome()
        defer { home.remove() }
        let (replies, run) = try serve(home, ["{not json", try Self.request(5, "frobnicate"), try Self.call(6, "delete_everything"), try Self.request(7, "ping")])
        #expect(run.status == 0)
        #expect(replies[5]?["error"]?["code"] == .int(-32601))
        #expect(replies[6]?["error"]?["code"] == .int(-32602))
        #expect(replies[7]?["result"] != nil)
        #expect(run.stdout.split(separator: "\n").count == 4)
    }

    @Test func mcpIsListedInTheHelp() throws {
        let home = CLIHome()
        defer { home.remove() }
        #expect(try home.run(["help", "mcp"]).status == 0)
        #expect(try home.run(["--help"]).stdout.contains("mcp"))
    }

    @Test func theServerOpensTheStoreUnderCadenceHomeOnly() throws {
        let home = CLIHome()
        defer { home.remove() }
        _ = try serve(home, [try Self.call(1, "log_entry", ["text": "Fixed a bug"])])
        #expect(FileManager.default.fileExists(atPath: home.database))
        let contents = try FileManager.default.contentsOfDirectory(atPath: home.home.path)
        #expect(contents.contains("cadence.db"))
    }
}
