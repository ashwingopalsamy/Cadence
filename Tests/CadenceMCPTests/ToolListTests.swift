import CadenceCore
import Foundation
import Testing

@testable import CadenceMCP

/// docs/SPEC.md section 9.2: nine tools in a fixed order, and nothing that deletes, seals, accepts or edits presence.
@Suite struct ToolListTests {
    static let nine = ["log_entry", "log_entries", "plan_add", "plan_update", "declare_day", "get_day", "query", "summary", "standup"]

    /// The `inputSchema` of `log_entry`, copied from docs/SPEC.md section 9.2.
    static let specSchema = """
        {
          "type": "object",
          "properties": {
            "text":         { "type": "string", "maxLength": 500 },
            "kind":         { "type": "string", "description": "Override the parsed kind, e.g. work.done, review.given, discussion.raised" },
            "date":         { "type": "string", "format": "date" },
            "occurred_at":  { "type": "string", "description": "RFC 3339, or HH:MM in local time" },
            "ticket":       { "type": "string" },
            "links":        { "type": "array", "maxItems": 5, "items": { "type": "object", "required": ["url"],
                              "properties": { "url": { "type": "string", "format": "uri" }, "kind": { "enum": ["pr", "ticket", "doc", "other"] } } } },
            "duration_min": { "type": "integer", "minimum": 1, "maximum": 720 },
            "quantity":     { "type": "integer", "minimum": 1, "maximum": 50 },
            "note":         { "type": "string", "maxLength": 1000 }
          },
          "required": ["text"],
          "additionalProperties": false
        }
        """

    static let specDescription =
        "Record one work outcome in Cadence, the user's local work log. Use after finishing something the user would mention in stand-up. Prefer 'text' in the user's words; Cadence parses ticket keys, kind, time and duration. Do not log routine tool calls."

    func listed() throws -> [JSONValue] {
        let h = try ToolHarness()
        let reply = try h.send(method: "tools/list", params: ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]])
        return try #require(reply.result?["tools"]?.arrayValue)
    }

    @Test func theToolListIsExactlyTheNineInTheSpecsOrder() throws {
        let tools = try listed()
        #expect(tools.compactMap { $0["name"]?.stringValue } == Self.nine)
        #expect(CadenceMCP.toolNames == Self.nine)
    }

    @Test func noToolDeletesSealsAcceptsOrTouchesPresenceOrConfig() throws {
        for tool in try listed() {
            let name = try #require(tool["name"]?.stringValue)
            for word in ["delete", "remove", "seal", "accept", "dismiss", "inbox", "presence", "config", "rebuild", "export", "collect"] {
                #expect(!name.contains(word), "\(name)")
            }
            // And no argument asks for one either.
            let properties = tool["inputSchema"]?["properties"]?.objectValue ?? [:]
            for key in properties.keys {
                for word in ["delete", "seal", "accept", "dismiss", "presence"] {
                    #expect(!key.contains(word), "\(name).\(key)")
                }
            }
        }
        // The one place an argument names a status is the read-only filter of query.
        let query = try #require(try listed().first { $0["name"] == "query" })
        #expect(query["inputSchema"]?["properties"]?["statuses"] != nil)
    }

    @Test func everyToolTakesAnObjectWithNoUnknownArguments() throws {
        for tool in try listed() {
            let name = tool["name"]?.stringValue ?? ""
            #expect(tool["inputSchema"]?["type"] == "object", "\(name)")
            #expect(tool["inputSchema"]?["additionalProperties"] == false, "\(name)")
            #expect((tool["description"]?.stringValue ?? "").count > 40, "\(name)")
            // Copy rules: no en or em dashes.
            #expect(!(tool["description"]?.stringValue ?? "").contains { $0 == "\u{2013}" || $0 == "\u{2014}" }, "\(name)")
        }
    }

    @Test func logEntryIsTheSpecsToolVerbatim() throws {
        let tool = try #require(try listed().first { $0["name"] == "log_entry" })
        #expect(tool["description"]?.stringValue == Self.specDescription)
        #expect(tool["inputSchema"] == (try JSONParser.parse(Self.specSchema)))
    }

    @Test func writeToolsAreRateLimitedAndReadToolsAreNot() throws {
        let h = try ToolHarness()
        let tools = CadenceMCP.tools(journal: h.provider)
        let writes = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.writes) })
        #expect(writes == [
            "log_entry": true, "log_entries": true, "plan_add": true, "plan_update": true, "declare_day": true,
            "get_day": false, "query": false, "summary": false, "standup": false,
        ])
    }

    @Test func theServerAnnouncesItselfAndHowToUseIt() throws {
        let h = try ToolHarness()
        let discovery = try h.send(method: "server/discover", params: ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]])
        #expect(discovery.result?["serverInfo"]?["name"] == "cadence")
        let instructions = try #require(discovery.result?["instructions"]?.stringValue)
        #expect(instructions.contains("dry_run") && instructions.contains("Inbox"))
        #expect(!instructions.contains { $0 == "\u{2013}" || $0 == "\u{2014}" })
    }
}
