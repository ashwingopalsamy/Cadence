import Foundation

/// One command to execute. Argv only: there is never a shell (docs/SPEC.md section 10.2).
public struct ProcessRequest: Sendable, Equatable {
    /// Absolute path to the executable. Relative paths are refused by every runner.
    public var executable: String
    public var arguments: [String]
    /// The complete environment. Nothing is inherited from the calling process.
    public var environment: [String: String]
    public var workingDirectory: URL
    /// Wall-clock limit before SIGTERM.
    public var timeout: Duration
    /// Time between SIGTERM and SIGKILL.
    public var killGrace: Duration
    /// Bytes of stdout kept; anything beyond is discarded and flagged.
    public var stdoutLimit: Int
    /// Bytes kept from the end of stderr.
    public var stderrTailLimit: Int

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL,
        timeout: Duration = .seconds(60),
        killGrace: Duration = .seconds(5),
        stdoutLimit: Int = 10 * 1024 * 1024,
        stderrTailLimit: Int = 64 * 1024
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.killGrace = killGrace
        self.stdoutLimit = stdoutLimit
        self.stderrTailLimit = stderrTailLimit
    }
}

/// What came back from a command.
public struct ProcessResult: Sendable, Equatable {
    public enum Termination: Sendable, Equatable {
        case exited(Int32)
        case signalled(Int32)
    }

    public var termination: Termination
    public var timedOut: Bool
    public var stdout: Data
    public var stdoutTruncated: Bool
    public var stderrTail: Data

    public init(termination: Termination, timedOut: Bool, stdout: Data, stdoutTruncated: Bool, stderrTail: Data) {
        self.termination = termination
        self.timedOut = timedOut
        self.stdout = stdout
        self.stdoutTruncated = stdoutTruncated
        self.stderrTail = stderrTail
    }

    public var succeeded: Bool { termination == .exited(0) && !timedOut }
}

/// Executes commands. The real implementation lives in CadenceIngest (the collector runner);
/// tests inject fakes so Core logic never spawns processes.
public protocol ProcessRunner: Sendable {
    func run(_ request: ProcessRequest) throws -> ProcessResult
}
