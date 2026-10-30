import Foundation

@testable import CadenceCore

/// Records every command and answers with a canned result. `onRun` lets a test play the part of the command.
final class RecordingRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ProcessRequest] = []
    private var canned: Result<ProcessResult, CadenceError> = .success(.exited(0))
    private var effect: (@Sendable (ProcessRequest) -> Void)?

    var requests: [ProcessRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func answer(with result: Result<ProcessResult, CadenceError>) {
        lock.lock()
        canned = result
        lock.unlock()
    }

    func onRun(_ body: @escaping @Sendable (ProcessRequest) -> Void) {
        lock.lock()
        effect = body
        lock.unlock()
    }

    func run(_ request: ProcessRequest) throws -> ProcessResult {
        lock.lock()
        recorded.append(request)
        let result = canned
        let body = effect
        lock.unlock()
        body?(request)
        return try result.get()
    }
}

extension ProcessResult {
    static func exited(_ code: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) -> ProcessResult {
        ProcessResult(
            termination: .exited(code), timedOut: timedOut, stdout: Data(stdout.utf8), stdoutTruncated: false,
            stderrTail: Data(stderr.utf8))
    }
}

/// A throwaway user home with Claude Code's files, and a folder holding a pretend `claude` program.
/// Nothing here reads the real home folder.
struct ClaudeHome {
    let home: URL
    let paths: ClaudeCodePaths
    let runner = RecordingRunner()

    init() {
        home = TestStore.tempDirectory("user-home")
        paths = ClaudeCodePaths(userHome: home)
    }

    /// A folder with an executable called `claude`, for the PATH the code under test is given.
    func installFakeClaude() -> URL {
        let bin = TestStore.tempDirectory("bin")
        let claude = bin.appendingPathComponent("claude")
        _ = FileManager.default.createFile(
            atPath: claude.path, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
        return bin
    }

    func environment(path: URL? = nil, extra: [String: String] = [:]) -> [String: String] {
        var environment = ["HOME": "/nonexistent-real-home", "LANG": "C", "SECRET_TOKEN": "keep-out"]
        environment["PATH"] = (path.map { $0.path + ":" } ?? "") + "/nonexistent-bin"
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    func setup(path: URL?) -> ClaudeCodeSetup {
        ClaudeCodeSetup(userHome: home, environment: environment(path: path), runner: runner)
    }

    @discardableResult
    func write(_ text: String, to url: URL, mode: Int = 0o644) -> URL {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
        return url
    }

    func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func mode(_ url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue
    }

    func writeSettings(_ text: String, mode: Int = 0o600) {
        write(text, to: paths.settings, mode: mode)
    }

    /// What `claude mcp add --scope user` leaves in `~/.claude.json`, with the unrelated keys it keeps there.
    func writeUserConfig(command: String? = nil, args: [String] = ["mcp"], serverName: String = "cadence") {
        let command = command ?? paths.cadenceBinary.path
        let argsJSON = args.map { "\"\($0)\"" }.joined(separator: ",")
        write(
            """
            {"numStartups": 7, "theme": "dark", "projects": {}, "mcpServers": {"other": {"type": "stdio", "command": "/bin/true", "args": []}, "\(serverName)": {"type": "stdio", "command": "\(command)", "args": [\(argsJSON)], "env": {}}}}
            """,
            to: paths.userConfig)
    }

    func installBinary() {
        write("#!/bin/sh\n", to: paths.cadenceBinary, mode: 0o755)
    }

    /// Every file and folder under the home with its mode, modification time and bytes.
    func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(atPath: home.path) else { return out }
        for case let relative as String in walker {
            let url = home.appendingPathComponent(relative)
            let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let kind = (attributes[.type] as? FileAttributeType) == .typeDirectory ? "dir" : "file"
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let bytes = kind == "file" ? ((try? Data(contentsOf: url)).map { Array($0) } ?? []) : []
            out[relative] = "\(kind) \(String(mode, radix: 8)) \(modified) \(bytes)"
        }
        return out
    }
}
