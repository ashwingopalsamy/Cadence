import CadenceCore
import Foundation
import Testing

@testable import CadenceMCP

/// docs/SPEC.md section 9.2: JSON-RPC 2.0 over stdio, both protocol revisions.
@Suite struct MCPProtocolTests {
    static let echo = MCPTool(
        name: "echo", description: "Says the text back.",
        inputSchema: [
            "type": "object", "additionalProperties": false, "required": ["text"],
            "properties": [
                "text": ["type": "string", "maxLength": 20], "times": ["type": "integer", "minimum": 1, "maximum": 3],
                "date": ["type": "string", "format": "date"], "kind": ["enum": ["pr", "doc"]],
            ],
        ],
        writes: true,
        call: { args throws(CadenceError) in
            let text = args["text"]?.stringValue ?? ""
            if text == "fail" { throw CadenceError.validation("text: cannot be fail") }
            let times = Int(args["times"]?.intValue ?? 1)
            return MCPToolResult(text: Array(repeating: text, count: times).joined(separator: " "), structured: ["text": .string(text)])
        })

    static let reader = MCPTool(
        name: "read", description: "Reads.", inputSchema: ["type": "object", "additionalProperties": false, "properties": [:]], writes: false,
        call: { _ throws(CadenceError) in MCPToolResult(text: String(repeating: "x", count: 25_000)) })

    static func server(clock: ManualClock = ManualClock(Date(timeIntervalSince1970: 1_790_000_000)), limit: Int = 60) throws -> MCPServer {
        try MCPServer(
            name: "cadence", version: "0.2.0", instructions: "Cadence is the user's local work log.", tools: [echo, reader],
            resources: [
                MCPResource(uri: "cadence://week/current", name: "This week", description: "The week so far.") { uri throws(CadenceError) in
                    uri == "cadence://week/current" ? "# Week" : nil
                },
                MCPResource(uri: "cadence://day/{date}", name: "A day", description: "One day.") { uri throws(CadenceError) in
                    guard uri.hasPrefix("cadence://day/") else { return nil }
                    let date = String(uri.dropFirst("cadence://day/".count))
                    guard LocalDate(date) != nil else { throw CadenceError.validation("not a date: \(date)") }
                    return "# \(date)"
                },
            ],
            prompts: [
                MCPPrompt(name: "standup", description: "Stand-up text.", arguments: [.init(name: "date", description: "Day", required: false)]) {
                    args throws(CadenceError) in "Write my stand-up for \(args["date"] ?? "today")."
                }
            ],
            clock: clock, writesPerMinute: limit)
    }

    static func send(_ server: MCPServer, _ message: String) throws -> JSONValue? {
        guard let reply = server.handle(line: Array(message.utf8)) else { return nil }
        #expect(!reply.contains(0x0A), "a reply must be one line")
        return try JSONParser.parse(bytes: reply)
    }

    static func request(_ id: Int, _ method: String, _ params: String = "{}", stateless: Bool = false) -> String {
        var p = params
        if stateless {
            let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}"#
            p = params == "{}" ? "{\(meta)}" : String(params.dropLast()) + ",\(meta)}"
        }
        return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(p)}"#
    }

    static func initialized(_ server: MCPServer, version: String = "2025-11-25") throws {
        _ = try send(server, request(1, "initialize", #"{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"test","version":"1"}}"#))
        #expect(try send(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    // MARK: - 2025-11-25

    @Test func initializeNegotiatesTheSessionRevision() throws {
        let server = try Self.server()
        let reply = try #require(try Self.send(server, Self.request(1, "initialize", #"{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}"#)))
        #expect(reply["id"] == 1 && reply["jsonrpc"] == "2.0")
        let result = try #require(reply["result"])
        #expect(result["protocolVersion"] == "2025-11-25")
        #expect(result["serverInfo"] == ["name": "cadence", "version": "0.2.0"])
        #expect(result["capabilities"]?["tools"] == ["listChanged": false])
        #expect(result["capabilities"]?["resources"] != nil && result["capabilities"]?["prompts"] != nil)
        #expect(result["instructions"] == "Cadence is the user's local work log.")
        #expect(result["resultType"] == "complete")
    }

    @Test func anOlderOrUnknownVersionGetsTheSessionRevisionOffered() throws {
        for version in ["2024-11-05", "2099-01-01"] {
            let reply = try Self.send(try Self.server(), Self.request(1, "initialize", #"{"protocolVersion":"\#(version)"}"#))
            #expect(reply?["result"]?["protocolVersion"] == "2025-11-25")
        }
    }

    @Test func requestsBeforeInitializeOrWithoutAVersionAreRefused() throws {
        let reply = try Self.send(try Self.server(), Self.request(2, "tools/list"))
        #expect(reply?["error"]?["code"] == .int(RPCError.invalidRequest))
        #expect(reply?["id"] == 2)
        // ping works at any time.
        #expect(try Self.send(try Self.server(), Self.request(3, "ping"))?["result"] == ["resultType": "complete"])
    }

    @Test func toolsAreListedInAFixedOrderWithTheirSchemas() throws {
        let server = try Self.server()
        try Self.initialized(server)
        let tools = try #require(try Self.send(server, Self.request(2, "tools/list"))?["result"]?["tools"]?.arrayValue)
        #expect(tools.map { $0["name"] } == ["echo", "read"])
        #expect(tools[0]["inputSchema"]?["required"] == ["text"])
        #expect(tools[0]["description"] == "Says the text back.")
    }

    @Test func aToolCallReturnsTextAndStructuredContent() throws {
        let server = try Self.server()
        try Self.initialized(server)
        let result = try #require(try Self.send(server, Self.request(3, "tools/call", #"{"name":"echo","arguments":{"text":"hi","times":2}}"#))?["result"])
        #expect(result["content"] == [["type": "text", "text": "hi hi"]])
        #expect(result["structuredContent"] == ["text": "hi"])
        #expect(result["isError"] == nil)
        #expect(result["resultType"] == "complete")
    }

    @Test func badArgumentsAndToolFailuresAreToolErrorsTheModelCanRead() throws {
        let server = try Self.server()
        try Self.initialized(server)
        let cases: [(String, String)] = [
            (#"{}"#, "Not done: text: is required."),
            (#"{"text":"hi","colour":"red"}"#, "Not done: colour: is not a known argument."),
            (#"{"text":"this text is far too long"}"#, "Not done: text: must be at most 20 characters."),
            (#"{"text":"hi","times":9}"#, "Not done: times: must be at most 3."),
            (#"{"text":"hi","times":"2"}"#, "Not done: times: must be a whole number."),
            (#"{"text":"hi","date":"29/10/2026"}"#, "Not done: date: must be a date as YYYY-MM-DD."),
            (#"{"text":"hi","kind":"video"}"#, "Not done: kind: must be one of pr, doc."),
            (#"{"text":"fail"}"#, "Not done: text: cannot be fail"),
        ]
        for (index, (arguments, text)) in cases.enumerated() {
            let result = try Self.send(server, Self.request(10 + index, "tools/call", #"{"name":"echo","arguments":\#(arguments)}"#))?["result"]
            #expect(result?["isError"] == true, "\(arguments)")
            #expect(result?["content"] == [["type": "text", "text": .string(text)]], "\(arguments)")
        }
    }

    @Test func anUnknownToolOrMethodIsAProtocolError() throws {
        let server = try Self.server()
        try Self.initialized(server)
        #expect(try Self.send(server, Self.request(4, "tools/call", #"{"name":"delete_everything"}"#))?["error"]?["code"] == .int(RPCError.invalidParams))
        #expect(try Self.send(server, Self.request(5, "sampling/createMessage"))?["error"]?["code"] == .int(RPCError.methodNotFound))
    }

    @Test func longResultsAreCutUnderTheLimit() throws {
        let server = try Self.server()
        try Self.initialized(server)
        let text = try #require(try Self.send(server, Self.request(6, "tools/call", #"{"name":"read"}"#))?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(text.count <= MCPServer.maxResultCharacters && text.hasSuffix("ask for a narrower range."))
    }

    @Test func writesAreLimitedPerMinuteAndReadsAreNot() throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_790_000_000))
        let server = try Self.server(clock: clock, limit: 3)
        try Self.initialized(server)
        let call = Self.request(7, "tools/call", #"{"name":"echo","arguments":{"text":"hi"}}"#)
        for _ in 0..<3 { #expect(try Self.send(server, call)?["result"] != nil) }
        #expect(try Self.send(server, call)?["error"]?["code"] == .int(RPCError.rateLimited))
        #expect(try Self.send(server, Self.request(8, "tools/call", #"{"name":"read"}"#))?["result"] != nil)
        clock.advance(by: 61)
        #expect(try Self.send(server, call)?["result"] != nil)
    }

    @Test func resourcesAndTemplates() throws {
        let server = try Self.server()
        try Self.initialized(server)
        #expect(try Self.send(server, Self.request(1, "resources/list"))?["result"]?["resources"]?.arrayValue?.map { $0["uri"] } == ["cadence://week/current"])
        #expect(try Self.send(server, Self.request(2, "resources/templates/list"))?["result"]?["resourceTemplates"]?.arrayValue?.map { $0["uriTemplate"] }
            == ["cadence://day/{date}"])
        let read = try Self.send(server, Self.request(3, "resources/read", #"{"uri":"cadence://day/2026-10-29"}"#))
        #expect(read?["result"]?["contents"] == [["uri": "cadence://day/2026-10-29", "mimeType": "text/markdown", "text": "# 2026-10-29"]])
        #expect(try Self.send(server, Self.request(4, "resources/read", #"{"uri":"cadence://day/yesterday"}"#))?["error"]?["code"] == .int(RPCError.invalidParams))
        #expect(try Self.send(server, Self.request(5, "resources/read", #"{"uri":"file:///etc/passwd"}"#))?["error"]?["code"] == .int(RPCError.invalidParams))
    }

    @Test func promptsAreListedAndRendered() throws {
        let server = try Self.server()
        try Self.initialized(server)
        #expect(try Self.send(server, Self.request(1, "prompts/list"))?["result"]?["prompts"]?.arrayValue?.map { $0["name"] } == ["standup"])
        let got = try Self.send(server, Self.request(2, "prompts/get", #"{"name":"standup","arguments":{"date":"2026-10-29"}}"#))
        #expect(got?["result"]?["messages"] == [["role": "user", "content": ["type": "text", "text": "Write my stand-up for 2026-10-29."]]])
    }

    // MARK: - 2026-07-28, stateless

    @Test func discoverDescribesTheServerWithoutASession() throws {
        let reply = try Self.send(try Self.server(), Self.request(1, "server/discover", "{}", stateless: true))
        let result = try #require(reply?["result"])
        #expect(result["supportedVersions"] == ["2026-07-28", "2025-11-25"])
        #expect(result["serverInfo"]?["name"] == "cadence")
        #expect(result["capabilities"]?["tools"] != nil)
        #expect(result["resultType"] == "complete")
    }

    @Test func statelessRequestsCarryTheirVersionAndNeedNoInitialize() throws {
        let server = try Self.server()
        let list = try Self.send(server, Self.request(1, "tools/list", "{}", stateless: true))
        #expect(list?["result"]?["tools"]?.arrayValue?.count == 2 && list?["result"]?["resultType"] == "complete")
        let call = try Self.send(server, Self.request(2, "tools/call", #"{"name":"echo","arguments":{"text":"hi"}}"#, stateless: true))
        #expect(call?["result"]?["content"] == [["type": "text", "text": "hi"]])
    }

    @Test func anUnsupportedStatelessVersionIsRefusedWithTheSupportedList() throws {
        let message = #"{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2030-01-01"}}}"#
        let error = try #require(try Self.send(try Self.server(), message)?["error"])
        #expect(error["code"] == .int(RPCError.invalidParams))
        #expect(error["data"] == ["supported": ["2026-07-28", "2025-11-25"], "requested": "2030-01-01"])
    }

    // MARK: - JSON-RPC framing

    @Test func malformedMessagesGetJSONRPCErrors() throws {
        let server = try Self.server()
        let cases: [(String, Int64)] = [
            ("{not json", RPCError.parse),
            (#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, RPCError.invalidRequest),
            (#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, RPCError.invalidRequest),
            (#"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#, RPCError.invalidRequest),
            (#"{"jsonrpc":"2.0","id":1,"method":"ping","params":[1]}"#, RPCError.invalidParams),
            (#"{"jsonrpc":"2.0","id":1}"#, RPCError.invalidRequest),
        ]
        for (message, code) in cases {
            #expect(try Self.send(server, message)?["error"]?["code"] == .int(code), "\(message)")
        }
        #expect(try Self.send(server, "   ") == nil)
        #expect(try Self.send(server, #"{"jsonrpc":"2.0","id":5,"result":{}}"#) == nil)  // a client response
        #expect(try Self.send(server, #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#) == nil)
        #expect(try Self.send(server, #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)?["id"] == "abc")
    }

    @Test func serveReadsLinesAndWritesOneReplyPerRequest() throws {
        let server = try Self.server()
        let input = Pipe()
        let output = Pipe()
        let lines = [
            Self.request(1, "initialize", #"{"protocolVersion":"2025-11-25"}"#),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            Self.request(2, "tools/list"),
            Self.request(3, "ping"),
        ].joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(lines.utf8))
        try input.fileHandleForWriting.close()
        server.serve(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try output.fileHandleForWriting.close()
        let replies = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        #expect(replies.count == 3)
        #expect(try replies.map { try JSONParser.parse(String($0))["id"] } == [1, 2, 3])
    }

    // MARK: - Audit findings

    @Test func fractionsAndUnsafeIntegersAreRefusedWithoutEchoingAnAlteredID() throws {
        let server = try Self.server()
        try Self.initialized(server)
        for message in [
            #"{"jsonrpc":"2.0","id":1.0,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":12345678901234567890,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":1e2,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"text":1.5}}}"#,
        ] {
            let reply = try Self.send(server, message)
            #expect(reply?["error"]?["code"] == .int(RPCError.invalidRequest), "\(message)")
            #expect(reply?["id"] == .null, "\(message)")
        }
        // A string field given a number is a tool error, never the number's text.
        let result = try Self.send(server, Self.request(5, "tools/call", #"{"name":"echo","arguments":{"text":15}}"#))?["result"]
        #expect(result?["content"] == [["type": "text", "text": "Not done: text: must be a string."]])
        #expect(try Self.send(server, #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#)?["error"]?["code"] == .int(RPCError.invalidRequest))
        #expect(try Self.send(server, #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)?["error"]?["code"] == .int(RPCError.invalidRequest))
    }

    @Test func malformedSchemaShapesAreRefusedAtRegistration() {
        func tool(_ properties: JSONValue, required: JSONValue? = nil) -> MCPTool {
            var schema: [String: JSONValue] = ["type": "object", "additionalProperties": false, "properties": properties]
            if let required { schema["required"] = required }
            return MCPTool(name: "t", description: "", inputSchema: .object(schema), writes: false, call: { _ throws(CadenceError) in MCPToolResult(text: "") })
        }
        let bad: [MCPTool] = [
            tool(["k": ["enum": "pr"]]),
            tool(["k": ["enum": []]]),
            tool(["k": ["type": "string", "enum": ["a", 1]]]),
            tool(["k": ["type": "string"]], required: "k"),
            tool(["k": ["type": "string"]], required: ["y"]),
            tool(["k": ["type": "string", "maxLength": "5"]]),
            tool(["k": ["type": "string", "minimum": 1]]),
            tool(["k": ["type": "integer", "format": "date"]]),
            tool(["k": ["required": ["url"], "properties": ["url": ["type": "string"]]]]),
            tool(["k": ["type": "array", "items": ["required": ["url"]]]]),
            tool(["k": ["type": "object", "properties": "x"]]),
        ]
        for t in bad {
            #expect(throws: CadenceError.self, "\(t.inputSchema)") { try MCPServer(name: "c", version: "1", tools: [t], clock: ManualClock(Date())) }
        }
        // The spec's log_entry links field is accepted and its nested checks run.
        let links = MCPTool(
            name: "links", description: "",
            inputSchema: [
                "type": "object", "additionalProperties": false,
                "properties": [
                    "links": [
                        "type": "array", "maxItems": 5,
                        "items": [
                            "type": "object", "required": ["url"],
                            "properties": ["url": ["type": "string", "format": "uri"], "kind": ["enum": ["pr", "ticket", "doc", "other"]]],
                        ],
                    ]
                ],
            ],
            writes: false, call: { _ throws(CadenceError) in MCPToolResult(text: "ok") })
        let server = try? MCPServer(name: "c", version: "1", tools: [links], clock: ManualClock(Date()))
        #expect(server != nil)
        if let server {
            for (arguments, text) in [
                (#"{"links":[{"nourl":1}]}"#, "Not done: links[0].url: is required."),
                (#"{"links":[{"url":"https://"}]}"#, "Not done: links[0].url: must be an http or https URL."),
                (#"{"links":[{"url":"https://example.com/pr/1","kind":"pr"}]}"#, "ok"),
            ] {
                let result = try? Self.send(server, Self.request(1, "tools/call", #"{"name":"links","arguments":\#(arguments)}"#, stateless: true))?["result"]
                #expect(result?["content"] == [["type": "text", "text": .string(text)]], "\(arguments)")
            }
        }
    }

    @Test func structuredContentResourcesAndPromptsStayUnderTheLimit() throws {
        let big = String(repeating: "y", count: 100_000)
        let tool = MCPTool(
            name: "big", description: "", inputSchema: ["type": "object", "additionalProperties": false, "properties": [:]], writes: false,
            call: { _ throws(CadenceError) in MCPToolResult(text: "short", structured: ["rows": .string(big)]) })
        let server = try MCPServer(
            name: "c", version: "1", tools: [tool],
            resources: [MCPResource(uri: "cadence://week/current", name: "w", description: "") { _ throws(CadenceError) in big }],
            prompts: [MCPPrompt(name: "p", description: "") { _ throws(CadenceError) in big }],
            clock: ManualClock(Date()))
        for (method, params) in [
            ("tools/call", #"{"name":"big"}"#), ("resources/read", #"{"uri":"cadence://week/current"}"#), ("prompts/get", #"{"name":"p"}"#),
        ] {
            let line = try #require(server.handle(line: Array(Self.request(1, method, params, stateless: true).utf8)))
            #expect(String(decoding: line, as: UTF8.self).unicodeScalars.count <= MCPServer.maxResultCharacters + 100, "\(method)")
            #expect(String(decoding: line, as: UTF8.self).contains("ask for a narrower range."), "\(method)")
        }
        // Combining marks cannot stretch a length limit or the result cap.
        let marks = "a" + String(repeating: "\u{0301}", count: 200)
        let echoServer = try Self.server()
        let result = try Self.send(echoServer, Self.request(2, "tools/call", #"{"name":"echo","arguments":{"text":"\#(marks)"}}"#, stateless: true))?["result"]
        #expect(result?["content"] == [["type": "text", "text": "Not done: text: must be at most 20 characters."]])
    }

    @Test func theHandshakeRevisionNeedsItsHandshake() throws {
        let server = try Self.server()
        let session = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-11-25"}}}"#
        #expect(try Self.send(server, session)?["error"]?["code"] == .int(RPCError.invalidRequest))
        // initialize asking for the stateless revision is offered the session revision instead.
        let reply = try Self.send(server, Self.request(2, "initialize", #"{"protocolVersion":"2026-07-28"}"#))
        #expect(reply?["result"]?["protocolVersion"] == "2025-11-25")
    }

    @Test func aClockSetBackDoesNotBlockWrites() throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_790_000_000))
        let server = try Self.server(clock: clock, limit: 2)
        try Self.initialized(server)
        let call = Self.request(7, "tools/call", #"{"name":"echo","arguments":{"text":"hi"}}"#)
        for _ in 0..<2 { #expect(try Self.send(server, call)?["result"] != nil) }
        clock.set(Date(timeIntervalSince1970: 1_790_000_000 - 3600 + 300))
        #expect(try Self.send(server, call)?["result"] != nil)
    }

    @Test func refusalsQuoteClientTextSafelyAndHideSystemDetail() throws {
        let message = #"{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2030-01-01\u0000\n"}}}"#
        #expect(try Self.send(try Self.server(), message)?["error"]?["data"]?["requested"] == "2030-01-01")
        let failing = MCPTool(
            name: "io", description: "", inputSchema: ["type": "object", "additionalProperties": false, "properties": [:]], writes: true,
            call: { _ throws(CadenceError) in throw CadenceError.io("cannot open /Users/someone/.cadence/cadence.db: disk I/O error") })
        let server = try MCPServer(name: "c", version: "1", tools: [failing], clock: ManualClock(Date()))
        let text = try Self.send(server, Self.request(1, "tools/call", #"{"name":"io"}"#, stateless: true))?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        #expect(text == "Not done: Cadence could not finish this; the details are in its log.")
    }

    @Test func serveHandlesOversizedFinalCRLFAndSplitLines() throws {
        let server = try Self.server()
        let input = Pipe()
        let output = Pipe()
        let first = Self.request(1, "ping", "{}", stateless: true)
        let writer = input.fileHandleForWriting
        let second = Self.request(2, "ping")
        // More than a pipe holds, so it is written while serve reads.
        let feeder = Thread {
            writer.write(Data(first.prefix(10).utf8))
            writer.write(Data((first.dropFirst(10) + "\r\n").utf8))
            writer.write(Data((second + "\n").utf8))
            writer.write(Data(repeating: 0x20, count: MCPServer.maxLine + 10))  // oversized and never ended
            try? writer.close()
        }
        feeder.start()
        server.serve(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try output.fileHandleForWriting.close()
        let replies = try String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map { try JSONParser.parse(String($0)) }
        #expect(replies.count == 3)
        #expect(replies.map { $0["id"] } == [1, 2, .null])
        #expect(replies[2]["error"]?["code"] == .int(RPCError.invalidRequest))
    }

    @Test func serveStopsWhenTheClientGoesAway() throws {
        let server = try Self.server()
        let input = Pipe()
        let output = Pipe()
        try output.fileHandleForReading.close()
        input.fileHandleForWriting.write(Data((Self.request(1, "ping", "{}", stateless: true) + "\n").utf8))
        try input.fileHandleForWriting.close()
        server.serve(input: input.fileHandleForReading, output: output.fileHandleForWriting)  // returns instead of dying of SIGPIPE
    }

    @Test func schemasUsingUnenforcedKeywordsAreRefused() {
        let bad = MCPTool(
            name: "bad", description: "", inputSchema: ["type": "object", "properties": ["x": ["type": "string", "pattern": "^a"]]], writes: false,
            call: { _ throws(CadenceError) in MCPToolResult(text: "") })
        #expect(throws: CadenceError.self) { try MCPServer(name: "c", version: "1", tools: [bad], clock: ManualClock(Date())) }
        #expect(throws: CadenceError.self) { try MCPServer(name: "c", version: "1", tools: [Self.echo, Self.echo], clock: ManualClock(Date())) }
    }
}
