// CadenceMCP: JSON-RPC 2.0 over stdio, the tool registry and both MCP protocol revisions
// (docs/SPEC.md section 9.2).
import CadenceCore
import CadenceIngest
import Foundation

public enum CadenceMCP {
    /// Protocol revisions this server speaks, newest first.
    public static let supportedRevisions = ["2026-07-28", "2025-11-25"]
    /// The revision with the `initialize` handshake and a session.
    public static let sessionRevision = "2025-11-25"
    /// The stateless revision: the version rides in each request's `_meta`, and `server/discover` replaces `initialize`.
    public static let statelessRevision = "2026-07-28"
    /// `_meta` keys read for the stateless revision's protocol version (docs/SPEC.md section 9.2, verify on the Mac).
    public static let versionMetaKeys = ["io.modelcontextprotocol/protocolVersion", "protocolVersion"]
}

/// What a tool returns: text for the model, and optionally the same answer as structured JSON.
public struct MCPToolResult: Sendable, Equatable {
    public var text: String
    public var structured: JSONValue?
    public var isError: Bool

    public init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }
}

/// One tool. The schema is checked when the server is built; arguments are validated against it before `call`.
public struct MCPTool: Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    /// Whether a call writes to the store; reads are not rate limited.
    public var writes: Bool
    public var call: @Sendable ([String: JSONValue]) throws(CadenceError) -> MCPToolResult

    public init(
        name: String, description: String, inputSchema: JSONValue, writes: Bool,
        call: @escaping @Sendable ([String: JSONValue]) throws(CadenceError) -> MCPToolResult
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.writes = writes
        self.call = call
    }
}

public struct MCPResource: Sendable {
    /// A fixed URI such as `cadence://week/current`, or a template such as `cadence://day/{date}`.
    public var uri: String
    public var name: String
    public var description: String
    public var mimeType: String
    /// Returns the text for a concrete URI, or nil when this resource does not serve it.
    public var read: @Sendable (String) throws(CadenceError) -> String?

    public init(
        uri: String, name: String, description: String, mimeType: String = "text/markdown",
        read: @escaping @Sendable (String) throws(CadenceError) -> String?
    ) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.read = read
    }

    public var isTemplate: Bool { uri.contains("{") }
}

public struct MCPPrompt: Sendable {
    public struct Argument: Sendable {
        public var name: String
        public var description: String
        public var required: Bool

        public init(name: String, description: String, required: Bool) {
            self.name = name
            self.description = description
            self.required = required
        }
    }

    public var name: String
    public var description: String
    public var arguments: [Argument]
    /// The user message text for the given arguments.
    public var render: @Sendable ([String: String]) throws(CadenceError) -> String

    public init(
        name: String, description: String, arguments: [Argument] = [],
        render: @escaping @Sendable ([String: String]) throws(CadenceError) -> String
    ) {
        self.name = name
        self.description = description
        self.arguments = arguments
        self.render = render
    }
}

/// JSON-RPC error codes the server uses.
public enum RPCError {
    public static let parse: Int64 = -32700
    public static let invalidRequest: Int64 = -32600
    public static let methodNotFound: Int64 = -32601
    public static let invalidParams: Int64 = -32602
    public static let internalError: Int64 = -32603
    /// Writes past the per-minute limit.
    public static let rateLimited: Int64 = -32029
}

/// The MCP server. `handle` takes one message line and returns the response line, or nil for a notification.
/// It never writes to stdout itself; `serve` owns the streams, and logging goes to the `log` closure (stderr).
public final class MCPServer: @unchecked Sendable {
    public static let maxLine = 1024 * 1024
    public static let maxResultCharacters = 20_000

    public let name: String
    public let version: String
    public let instructions: String?
    let tools: [MCPTool]
    let resources: [MCPResource]
    let prompts: [MCPPrompt]
    let clock: any Clock
    let writesPerMinute: Int
    let log: @Sendable (String) -> Void

    private let lock = NSLock()
    /// The revision agreed in `initialize`, for the session revision.
    private var negotiated: String?
    private var recentWrites: [Date] = []

    public init(
        name: String, version: String, instructions: String? = nil, tools: [MCPTool], resources: [MCPResource] = [],
        prompts: [MCPPrompt] = [], clock: any Clock, writesPerMinute: Int = 60, log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws(CadenceError) {
        var seen = Set<String>()
        for tool in tools {
            guard seen.insert(tool.name).inserted else { throw .validation("tool \(tool.name): registered twice") }
            try JSONSchema.check(tool.inputSchema, at: "tool \(tool.name).inputSchema")
            guard tool.inputSchema.objectValue?["type"] == "object" else { throw .validation("tool \(tool.name): inputSchema must be an object schema") }
        }
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.clock = clock
        self.writesPerMinute = writesPerMinute
        self.log = log
    }

    // MARK: - Transport

    /// Reads newline-delimited JSON-RPC from `input` until end of file and writes one line per response.
    public func serve(input: FileHandle, output: FileHandle) {
        var pending: [UInt8] = []
        var discarding = false
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            for byte in chunk {
                if byte == 0x0A {
                    if !discarding, let reply = handle(line: pending) { output.write(Data(reply + [0x0A])) }
                    if discarding, let reply = Self.errorLine(id: .null, code: RPCError.invalidRequest, message: "the message is larger than 1 MB") {
                        output.write(Data(reply + [0x0A]))
                    }
                    pending.removeAll(keepingCapacity: true)
                    discarding = false
                } else if !discarding {
                    pending.append(byte)
                    if pending.count > Self.maxLine {
                        pending.removeAll()
                        discarding = true
                    }
                }
            }
        }
        if !pending.isEmpty, !discarding, let reply = handle(line: pending) { output.write(Data(reply + [0x0A])) }
    }

    // MARK: - Messages

    /// One message in, at most one response out. Blank lines are ignored.
    public func handle(line: [UInt8]) -> [UInt8]? {
        var bytes = line[...]
        if bytes.last == 0x0D { bytes = bytes.dropLast() }
        if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { return nil }
        guard bytes.count <= Self.maxLine else {
            return Self.errorLine(id: .null, code: RPCError.invalidRequest, message: "the message is larger than 1 MB")
        }
        let message: JSONValue
        do {
            // Clients may send floats; they reach tools as text and fail schema checks with a clear message.
            message = try JSONParser.parseKeepingNumberText(bytes: Array(bytes))
        } catch {
            return Self.errorLine(id: .null, code: RPCError.parse, message: "parse error: the message is not valid JSON")
        }
        guard let object = message.objectValue else {
            return Self.errorLine(id: .null, code: RPCError.invalidRequest, message: "a message must be one JSON object; batches are not supported")
        }
        let id = object["id"]
        if let id, !(id.stringValue != nil || id.intValue != nil) {
            return Self.errorLine(id: .null, code: RPCError.invalidRequest, message: "id must be a string or an integer")
        }
        guard object["jsonrpc"] == "2.0", let method = object["method"]?.stringValue else {
            // A response from the client (to a request we never send) or a malformed message.
            if id != nil, object["method"] == nil, object["result"] != nil || object["error"] != nil { return nil }
            return Self.errorLine(id: id ?? .null, code: RPCError.invalidRequest, message: "expected jsonrpc 2.0 with a method")
        }
        let params = object["params"] ?? .object([:])
        guard let paramObject = params.objectValue else {
            return id.flatMap { Self.errorLine(id: $0, code: RPCError.invalidParams, message: "params must be an object") }
        }

        guard let id else {
            notify(method)
            return nil
        }
        switch respond(method: method, params: paramObject) {
        case .success(var result):
            result["resultType"] = "complete"
            return Self.encode(["jsonrpc": "2.0", "id": id, "result": .object(result)])
                ?? Self.errorLine(id: id, code: RPCError.internalError, message: "the result could not be encoded")
        case .failure(let error):
            return Self.errorLine(id: id, code: error.code, message: error.message, data: error.data)
        }
    }

    struct Failure: Error {
        var code: Int64
        var message: String
        var data: JSONValue? = nil
    }

    private func notify(_ method: String) {
        switch method {
        case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed": break
        default: log("mcp: ignored notification \(method)")
        }
    }

    private func respond(method: String, params: [String: JSONValue]) -> Result<[String: JSONValue], Failure> {
        if method == "initialize" { return initialize(params) }
        if method == "ping" { return .success([:]) }
        if method == "server/discover" { return .success(discovery()) }

        // Which revision governs this request: the stateless revision names itself in _meta on every request;
        // otherwise the session agreed in initialize.
        let meta = params["_meta"]?.objectValue ?? [:]
        if let stated = CadenceMCP.versionMetaKeys.lazy.compactMap({ meta[$0]?.stringValue }).first {
            guard CadenceMCP.supportedRevisions.contains(stated) else { return .failure(unsupported(stated)) }
        } else if currentSession() == nil {
            return .failure(Failure(
                code: RPCError.invalidRequest,
                message: "call initialize first, or send the protocol version in _meta (stateless revision)"))
        }

        switch method {
        case "tools/list":
            return .success(["tools": .array(tools.map(Self.describe))])
        case "tools/call":
            return callTool(params)
        case "resources/list":
            return .success(["resources": .array(resources.filter { !$0.isTemplate }.map(Self.describe))])
        case "resources/templates/list":
            return .success(["resourceTemplates": .array(resources.filter(\.isTemplate).map(Self.describeTemplate))])
        case "resources/read":
            return readResource(params)
        case "prompts/list":
            return .success(["prompts": .array(prompts.map(Self.describe))])
        case "prompts/get":
            return getPrompt(params)
        default:
            return .failure(Failure(code: RPCError.methodNotFound, message: "method not found: \(EnvelopeText.printable(method))"))
        }
    }

    private func currentSession() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return negotiated
    }

    private func initialize(_ params: [String: JSONValue]) -> Result<[String: JSONValue], Failure> {
        guard let requested = params["protocolVersion"]?.stringValue else {
            return .failure(Failure(code: RPCError.invalidParams, message: "initialize needs protocolVersion"))
        }
        // The client's version when we speak it, otherwise the session revision we offer instead.
        let agreed = CadenceMCP.supportedRevisions.contains(requested) ? requested : CadenceMCP.sessionRevision
        lock.lock()
        negotiated = agreed
        lock.unlock()
        var result: [String: JSONValue] = [
            "protocolVersion": .string(agreed), "capabilities": capabilities,
            "serverInfo": ["name": .string(name), "version": .string(version)],
        ]
        if let instructions { result["instructions"] = .string(instructions) }
        return .success(result)
    }

    private func discovery() -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "supportedVersions": .array(CadenceMCP.supportedRevisions.map(JSONValue.string)), "capabilities": capabilities,
            "serverInfo": ["name": .string(name), "version": .string(version)],
        ]
        if let instructions { result["instructions"] = .string(instructions) }
        return result
    }

    private var capabilities: JSONValue {
        var caps: [String: JSONValue] = ["tools": ["listChanged": false]]
        if !resources.isEmpty { caps["resources"] = ["listChanged": false, "subscribe": false] }
        if !prompts.isEmpty { caps["prompts"] = ["listChanged": false] }
        return .object(caps)
    }

    private func unsupported(_ version: String) -> Failure {
        Failure(
            code: RPCError.invalidParams, message: "unsupported protocol version",
            data: ["supported": .array(CadenceMCP.supportedRevisions.map(JSONValue.string)), "requested": .string(version)])
    }

    // MARK: - Tools

    private func callTool(_ params: [String: JSONValue]) -> Result<[String: JSONValue], Failure> {
        guard let name = params["name"]?.stringValue else { return .failure(Failure(code: RPCError.invalidParams, message: "tools/call needs a name")) }
        guard let tool = tools.first(where: { $0.name == name }) else {
            return .failure(Failure(code: RPCError.invalidParams, message: "unknown tool: \(EnvelopeText.printable(name))"))
        }
        let arguments = params["arguments"] ?? .object([:])
        // Bad arguments are a tool error, not a protocol error, so the model can read why and try again.
        if let problem = JSONSchema.violation(of: tool.inputSchema, by: arguments) {
            return .success(Self.toolResult(MCPToolResult(text: "Not done: \(problem).", isError: true)))
        }
        if tool.writes, !admitWrite() {
            return .failure(Failure(code: RPCError.rateLimited, message: "too many writes: at most \(writesPerMinute) a minute"))
        }
        do throws(CadenceError) {
            return .success(Self.toolResult(try tool.call(arguments.objectValue ?? [:])))
        } catch {
            log("mcp: \(name) failed: \(error.message)")
            return .success(Self.toolResult(MCPToolResult(text: "Not done: \(error.message)", isError: true)))
        }
    }

    /// A sliding one-minute window over write calls.
    private func admitWrite() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now()
        recentWrites.removeAll { now.timeIntervalSince($0) >= 60 }
        guard recentWrites.count < writesPerMinute else { return false }
        recentWrites.append(now)
        return true
    }

    static func toolResult(_ result: MCPToolResult) -> [String: JSONValue] {
        var text = result.text
        if text.count > maxResultCharacters {
            text = String(text.prefix(maxResultCharacters - 60)) + "\n… cut at \(maxResultCharacters) characters; ask for a narrower range."
        }
        var out: [String: JSONValue] = ["content": [["type": "text", "text": .string(text)]]]
        if let structured = result.structured { out["structuredContent"] = structured }
        if result.isError { out["isError"] = true }
        return out
    }

    private static func describe(_ tool: MCPTool) -> JSONValue {
        ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema]
    }

    // MARK: - Resources and prompts

    private func readResource(_ params: [String: JSONValue]) -> Result<[String: JSONValue], Failure> {
        guard let uri = params["uri"]?.stringValue else { return .failure(Failure(code: RPCError.invalidParams, message: "resources/read needs a uri")) }
        for resource in resources {
            do throws(CadenceError) {
                if let text = try resource.read(uri) {
                    return .success(["contents": [["uri": .string(uri), "mimeType": .string(resource.mimeType), "text": .string(text)]]])
                }
            } catch {
                return .failure(Failure(code: RPCError.invalidParams, message: error.message))
            }
        }
        return .failure(Failure(code: RPCError.invalidParams, message: "unknown resource: \(EnvelopeText.printable(uri))", data: ["uri": .string(uri)]))
    }

    private func getPrompt(_ params: [String: JSONValue]) -> Result<[String: JSONValue], Failure> {
        guard let name = params["name"]?.stringValue, let prompt = prompts.first(where: { $0.name == name }) else {
            return .failure(Failure(code: RPCError.invalidParams, message: "unknown prompt"))
        }
        var arguments: [String: String] = [:]
        for (key, value) in params["arguments"]?.objectValue ?? [:] {
            guard let text = value.stringValue else { return .failure(Failure(code: RPCError.invalidParams, message: "prompt arguments are strings")) }
            arguments[key] = text
        }
        for argument in prompt.arguments where argument.required && arguments[argument.name] == nil {
            return .failure(Failure(code: RPCError.invalidParams, message: "prompt \(name) needs \(argument.name)"))
        }
        do throws(CadenceError) {
            let text = try prompt.render(arguments)
            return .success([
                "description": .string(prompt.description),
                "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]],
            ])
        } catch {
            return .failure(Failure(code: RPCError.invalidParams, message: error.message))
        }
    }

    private static func describe(_ resource: MCPResource) -> JSONValue {
        ["uri": .string(resource.uri), "name": .string(resource.name), "description": .string(resource.description), "mimeType": .string(resource.mimeType)]
    }

    private static func describeTemplate(_ resource: MCPResource) -> JSONValue {
        ["uriTemplate": .string(resource.uri), "name": .string(resource.name), "description": .string(resource.description), "mimeType": .string(resource.mimeType)]
    }

    private static func describe(_ prompt: MCPPrompt) -> JSONValue {
        [
            "name": .string(prompt.name), "description": .string(prompt.description),
            "arguments": .array(prompt.arguments.map {
                ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)]
            }),
        ]
    }

    // MARK: - Encoding

    static func encode(_ value: JSONValue) -> [UInt8]? {
        try? CanonicalJSON.bytes(value)
    }

    static func errorLine(id: JSONValue, code: Int64, message: String, data: JSONValue? = nil) -> [UInt8]? {
        var error: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { error["data"] = data }
        return encode(["jsonrpc": "2.0", "id": id, "error": .object(error)])
    }
}

/// Text from a client, safe to quote back: control characters out, at most 60 characters.
enum EnvelopeText {
    static func printable(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.properties.generalCategory != .control }.map(Character.init).prefix(60))
    }
}
