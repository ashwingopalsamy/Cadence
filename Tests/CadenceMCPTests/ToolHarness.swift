import CadenceCore
import Foundation
import Testing

@testable import CadenceMCP

/// Sequential, readable ids: 01TEST00000000000000000001, ...
final class CountingIDs: IdentifierSource, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        let digits = String(n)
        return "01TEST" + String(repeating: "0", count: 20 - digits.count) + digits
    }
}

/// One reply to a `tools/call`, taken apart.
struct ToolReply {
    let raw: JSONValue

    var result: JSONValue? { raw["result"] }
    var rpcError: JSONValue? { raw["error"] }
    var isError: Bool { result?["isError"] == true }
    var text: String { result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "" }
    var structured: JSONValue? { result?["structuredContent"] }

    /// The characters a client receives: the text plus the structured JSON.
    var size: Int {
        text.count + ((try? structured.map { try CanonicalJSON.string($0) })?.count ?? 0)
    }
}

/// A server over a real SQLite store in a temp folder, on a clock that stands still: Thursday 2026-10-29,
/// 18:00 in Kolkata. Every call opens its own journal, as `cadence mcp` does.
final class ToolHarness: @unchecked Sendable {
    static let zoneID = "Asia/Kolkata"
    static let today = LocalDate("2026-10-29")!
    static let yesterday = LocalDate("2026-10-28")!

    let directory: URL
    let clock: ManualClock
    let ids = CountingIDs()
    let server: MCPServer
    let provider: JournalProvider
    private let path: String
    private let lock = NSLock()
    private var counter = 100

    init(failWith failure: CadenceError? = nil) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cadence-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let zone = TimeZone(identifier: Self.zoneID)!
        let clock = ManualClock(Timestamp.instant(clockTime: "18:00", on: Self.today, in: zone)!)
        let ids = self.ids
        let path = directory.appendingPathComponent("cadence.db").path
        let provider: JournalProvider = { () throws(CadenceError) -> Journal in
            if let failure { throw failure }
            let store = try SQLiteStore(path: path, clock: clock, ids: ids, projector: LedgerProjector())
            return try Journal(
                store: store, config: Config.defaults(timezone: ToolHarness.zoneID), clock: clock, ids: ids, actor: .mcp)
        }
        self.directory = directory
        self.clock = clock
        self.path = path
        self.provider = provider
        self.server = try CadenceMCP.server(journal: provider, clock: clock, version: "test")
        // The first journal writes the genesis event; do it now so tests count only what they cause.
        if failure == nil { _ = try provider() }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// A journal on the same store, for setting up what the tools cannot write and for reading back.
    func journal() throws -> Journal { try provider() }

    func events() throws -> [Event] {
        let store = try SQLiteStore(path: path, clock: clock, ids: ids, projector: LedgerProjector())
        return try store.events(after: 0, limit: 1_000_000)
    }

    func eventCount() throws -> Int { try events().count }

    /// `tools/call` in the stateless revision, so no handshake is needed.
    @discardableResult
    func call(_ tool: String, _ arguments: JSONValue = [:]) throws -> ToolReply {
        try send(
            method: "tools/call",
            params: ["name": .string(tool), "arguments": arguments, "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]])
    }

    func send(method: String, params: JSONValue) throws -> ToolReply {
        lock.lock()
        counter += 1
        let id = counter
        lock.unlock()
        let message: JSONValue = ["jsonrpc": "2.0", "id": .int(Int64(id)), "method": .string(method), "params": params]
        let reply = try #require(server.handle(line: try CanonicalJSON.bytes(message)))
        return ToolReply(raw: try JSONParser.parse(bytes: reply))
    }

    /// Events written by the MCP actor, in order.
    func agentEvents() throws -> [Event] { try events().filter { $0.actor == .mcp } }
}
