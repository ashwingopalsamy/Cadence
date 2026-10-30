import Foundation

/// Runs one command with Foundation's `Process`: argv only, the exact environment given, an optional
/// stdin, bounded output and a wall-clock limit (docs/SPEC.md section 10.2). The CLI uses it for
/// `pbcopy`; collectors get the same behaviour through the same type.
public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var tail = Data()
        private var truncated = false
        private var timedOut = false

        func addOut(_ chunk: Data, limit: Int) {
            lock.lock()
            defer { lock.unlock() }
            let room = max(0, limit - out.count)
            if chunk.count > room { truncated = true }
            out.append(chunk.prefix(room))
        }

        func addErr(_ chunk: Data, limit: Int) {
            lock.lock()
            defer { lock.unlock() }
            tail.append(chunk)
            if tail.count > limit { tail = tail.suffix(limit) }
        }

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }

        var snapshot: (out: Data, tail: Data, truncated: Bool, timedOut: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (out, tail, truncated, timedOut)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    public func run(_ request: ProcessRequest) throws -> ProcessResult {
        guard request.executable.hasPrefix("/") else {
            throw CadenceError.validation("process: the executable must be an absolute path")
        }
        // A child that exits before reading its stdin must not take this process down with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.workingDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = request.stdin == nil ? FileHandle.nullDevice : stdin
        do {
            try process.run()
        } catch {
            throw CadenceError.io("cannot run \(request.executable): \(error.localizedDescription)")
        }

        let capture = Capture()
        let group = DispatchGroup()
        let queue = DispatchQueue.global()
        queue.async(group: group) {
            while case let chunk = stdout.fileHandleForReading.availableData, !chunk.isEmpty {
                capture.addOut(chunk, limit: request.stdoutLimit)
            }
        }
        queue.async(group: group) {
            while case let chunk = stderr.fileHandleForReading.availableData, !chunk.isEmpty {
                capture.addErr(chunk, limit: request.stderrTailLimit)
            }
        }
        if let input = request.stdin {
            queue.async(group: group) {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }

        let pid = process.processIdentifier
        let kill = DispatchWorkItem {
            capture.markTimedOut()
            process.terminate()
            queue.asyncAfter(deadline: .now() + Self.seconds(request.killGrace)) {
                if process.isRunning { Foundation.kill(pid, SIGKILL) }
            }
        }
        queue.asyncAfter(deadline: .now() + Self.seconds(request.timeout), execute: kill)
        process.waitUntilExit()
        kill.cancel()
        group.wait()

        let seen = capture.snapshot
        let status = process.terminationStatus
        return ProcessResult(
            termination: process.terminationReason == .uncaughtSignal ? .signalled(status) : .exited(status),
            timedOut: seen.timedOut, stdout: seen.out, stdoutTruncated: seen.truncated, stderrTail: seen.tail)
    }
}
