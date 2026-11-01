import Foundation

/// The `cadence doctor` line for FileVault (docs/SPEC.md section 13.1: "`cadence doctor` reports whether FileVault is
/// on"). The store sits in a 0700 folder with 0600 files, which keeps other accounts out but not someone holding the
/// disk, so on a Mac this asks `fdesetup status` and reports what it says.
///
/// It is advice, never a failure: Off and an answer that cannot be read are `warn`, so doctor's exit code does not
/// depend on it. An answer is read only from a clean exit; anything else is "unknown", which is not the same as off.
/// Off macOS there is no `fdesetup`, so the line says it does not apply and nothing runs.
public struct FileVaultCheck: Sendable {
    public static let name = "filevault"
    /// Absolute, so a `PATH` entry can never stand in for it.
    public static let executable = "/usr/bin/fdesetup"

    let runner: any ProcessRunner
    let platform: HostPlatform
    let workingDirectory: URL

    public init(runner: any ProcessRunner, platform: HostPlatform, workingDirectory: URL) {
        self.runner = runner
        self.platform = platform
        self.workingDirectory = workingDirectory
    }

    /// What `fdesetup status` said.
    enum Status: Equatable {
        case on, off, unknown
    }

    public func run() -> AgentChecks.Result {
        let name = Self.name
        guard platform == .macOS else {
            return AgentChecks.Result(name: name, level: .ok, detail: "not applicable on this system")
        }
        let request = ProcessRequest(
            executable: Self.executable, arguments: ["status"],
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], workingDirectory: workingDirectory,
            timeout: .seconds(5))
        let result: ProcessResult
        do {
            result = try runner.run(request)
        } catch {
            return AgentChecks.Result(name: name, level: .warn, detail: "unknown, fdesetup could not be run")
        }
        if result.timedOut {
            return AgentChecks.Result(name: name, level: .warn, detail: "unknown, fdesetup did not answer in time")
        }
        // stderr is not copied into the report: it can hold anything.
        guard result.succeeded, !result.stdoutTruncated else {
            return AgentChecks.Result(name: name, level: .warn, detail: "unknown, fdesetup status did not give an answer")
        }
        switch Self.parse(result.stdout) {
        case .on:
            return AgentChecks.Result(name: name, level: .ok, detail: "FileVault is on, so the work log is encrypted at rest")
        case .off:
            return AgentChecks.Result(
                name: name, level: .warn,
                detail:
                    "FileVault is off, so the work log is not encrypted at rest; turn it on in System Settings, Privacy & Security, FileVault"
            )
        case .unknown:
            return AgentChecks.Result(
                name: name, level: .warn, detail: "unknown, fdesetup status gave an answer this cadence does not recognise")
        }
    }

    /// The first line that holds anything must be `FileVault is On.` or `FileVault is Off.` (the full stop is optional).
    /// Lines after it, such as progress or deferred enablement, do not change the answer. Anything else is unknown.
    static func parse(_ output: Data) -> Status {
        let text = String(decoding: output, as: UTF8.self)
        guard let first = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return .unknown }
        switch first {
        case "FileVault is On.", "FileVault is On": return .on
        case "FileVault is Off.", "FileVault is Off": return .off
        default: return .unknown
        }
    }
}
