import CadenceCore
import Foundation
import Testing

@testable import CadenceMCP

/// An agent cannot reopen a day (docs/SPEC.md sections 3 and 9): there is no tool for it, and the ledger refuses the
/// event from the MCP actor even if some other code path tried to write it.
@Suite struct ReopenGuardTests {
    func sealedHarness() throws -> ToolHarness {
        let h = try ToolHarness()
        _ = try h.journal().seal(ToolHarness.today, actor: .cli)
        return h
    }

    @Test func noToolIsNamedOrDescribedAsReopeningADay() throws {
        let h = try ToolHarness()
        let reply = try h.send(method: "tools/list", params: ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]])
        let tools = try #require(reply.result?["tools"]?.arrayValue)
        #expect(tools.count == 9)
        for tool in tools {
            let name = tool["name"]?.stringValue ?? ""
            #expect(!name.contains("reopen") && !name.contains("unseal"), "\(name)")
            let text = (tool["description"]?.stringValue ?? "").lowercased()
            #expect(!text.contains("reopen") && !text.contains("unseal"), "\(name)")
            #expect(tool["inputSchema"]?["properties"]?["reopen"] == nil, "\(name)")
        }
        #expect(!CadenceMCP.toolNames.contains { $0.contains("reopen") })
    }

    @Test func noToolCallReopensASealedDay() throws {
        let h = try sealedHarness()
        let before = try h.eventCount()
        // Every tool, with an argument that asks for a reopen, is refused as an unknown argument; the ones that need
        // no arguments run and leave the day sealed.
        for tool in CadenceMCP.toolNames {
            let reply = try h.call(tool, ["reopen": true, "date": "2026-10-29"])
            #expect(reply.isError || reply.rpcError != nil, "\(tool)")
        }
        for tool in ["get_day", "query", "summary", "standup"] { _ = try h.call(tool) }
        #expect(try h.events().allSatisfy { $0.type != "day.reopened" })
        #expect(try h.journal().dayView(ToolHarness.today).day.sealedAt != nil)
        // Only the stand-up's witness checkpoint may have been added.
        let added = try h.events().dropFirst(before).map(\.type)
        #expect(Set(added).isSubset(of: ["witness.checkpoint"]))
    }

    @Test func theJournalRefusesTheMCPActor() throws {
        let h = try sealedHarness()
        let before = try h.eventCount()
        let journal = try h.journal()
        #expect(throws: CadenceError.validation("only you can reopen a day; use the app or cadence day reopen")) {
            try journal.reopen(day: ToolHarness.today, actor: .mcp)
        }
        #expect(try h.eventCount() == before)
        #expect(try h.journal().dayView(ToolHarness.today).day.sealedAt != nil)
    }

    @Test func theLedgerRefusesTheEventFromTheMCPActor() throws {
        let h = try sealedHarness()
        let store = try h.journal().store
        let before = try store.eventCount()
        #expect(throws: CadenceError.self) {
            try store.append([EventPayload.dayReopened(DayReopened(day: "2026-10-29")).draft(actor: .mcp)])
        }
        #expect(try store.eventCount() == before)
        #expect(try h.journal().dayView(ToolHarness.today).day.sealedAt != nil)
        // The same event from the user's own writers is accepted.
        _ = try h.journal().reopen(day: ToolHarness.today, actor: .cli)
        #expect(try h.journal().dayView(ToolHarness.today).day.sealedAt == nil)
    }
}
