import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Runs one command with `posix_spawn`: argv only, the exact environment given, an optional stdin, bounded output
/// and a wall-clock limit (docs/SPEC.md section 10.2). The CLI uses it for `pbcopy` and `pmset`; collectors get the
/// same behaviour through the same type.
///
/// The child leads its own process group, so the timeout's SIGTERM and SIGKILL reach everything it started, and
/// anything still running when it exits is killed. A grandchild holding the pipes open cannot stretch a run past
/// the limit.
public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    /// How long the pipes may stay open after the command exits or is killed, before reading stops.
    static let drainLimit: Double = 1

    public func run(_ request: ProcessRequest) throws -> ProcessResult {
        guard request.executable.hasPrefix("/") else {
            throw CadenceError.validation("process: the executable must be an absolute path")
        }
        for text in [request.executable] + request.arguments + request.environment.flatMap({ [$0.key, $0.value] })
        where text.utf8.contains(0) {
            throw CadenceError.validation("process: arguments and environment must not contain NUL")
        }
        // A child that exits before reading its stdin must not take this process down with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)

        let out = try Self.pipe()
        let err = try Self.pipe()
        let input = request.stdin == nil ? nil : try Self.pipe()
        defer {
            close(out.0)
            close(err.0)
        }
        let pid: pid_t
        do {
            pid = try spawn(request, out: out.1, err: err.1, input: input?.0)
        } catch {
            let leftover: [Int32] = [out.1, err.1, input?.0 ?? -1, input?.1 ?? -1]
            for fd in leftover where fd >= 0 { close(fd) }
            throw error
        }
        // The child holds its own copies; the parent keeps only the read ends and the stdin writer.
        close(out.1)
        close(err.1)
        if let input {
            close(input.0)
            let writer = input.1
            let bytes = request.stdin!
            Thread {
                bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(writer, raw.baseAddress! + offset, raw.count - offset)
                        if n <= 0 { break }
                        offset += n
                    }
                }
                close(writer)
            }.start()
        }

        var stdout = Data()
        var tail = Data()
        var truncated = false
        var timedOut = false
        var status: Int32?
        let start = Date()
        let timeout = Self.seconds(request.timeout)
        let grace = Self.seconds(request.killGrace)
        var termAt: Date?
        var killed = false
        var stopReadingAt: Date?
        var open: [Int32] = [out.0, err.0]
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            let now = Date()
            if status == nil {
                var raw: Int32 = 0
                if waitpid(pid, &raw, WNOHANG) == pid {
                    status = raw
                    // Leftovers of the command's group must not outlive it or hold the pipes.
                    Foundation.kill(-pid, SIGKILL)
                    stopReadingAt = now.addingTimeInterval(Self.drainLimit)
                }
            }
            if status == nil {
                if termAt == nil, now.timeIntervalSince(start) >= timeout {
                    timedOut = true
                    termAt = now
                    Foundation.kill(-pid, SIGTERM)
                } else if let termAt, !killed, now.timeIntervalSince(termAt) >= grace {
                    killed = true
                    Foundation.kill(-pid, SIGKILL)
                }
            }
            if open.isEmpty && status != nil { break }
            if let stopReadingAt, now >= stopReadingAt { break }

            var fds = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = fds.isEmpty ? 0 : poll(&fds, nfds_t(fds.count), 50)
            if fds.isEmpty { usleep(20_000) }
            guard ready > 0 else { continue }
            for entry in fds where entry.revents != 0 {
                let n = read(entry.fd, &buffer, buffer.count)
                if n <= 0 {
                    open.removeAll { $0 == entry.fd }
                    continue
                }
                let chunk = Data(buffer[0..<n])
                if entry.fd == out.0 {
                    let room = max(0, request.stdoutLimit - stdout.count)
                    if chunk.count > room { truncated = true }
                    stdout.append(chunk.prefix(room))
                } else {
                    tail.append(chunk)
                    if tail.count > request.stderrTailLimit { tail = tail.suffix(request.stderrTailLimit) }
                }
            }
        }
        if status == nil {
            // Reading stopped before the command was reaped: make sure it is gone, then collect it.
            Foundation.kill(-pid, SIGKILL)
            var raw: Int32 = 0
            _ = waitpid(pid, &raw, 0)
            status = raw
        }
        let raw = status!
        let signalNumber = raw & 0x7F
        let termination: ProcessResult.Termination =
            signalNumber == 0 ? .exited((raw >> 8) & 0xFF) : .signalled(signalNumber)
        return ProcessResult(termination: termination, timedOut: timedOut, stdout: stdout, stdoutTruncated: truncated, stderrTail: tail)
    }

    private func spawn(_ request: ProcessRequest, out: Int32, err: Int32, input: Int32?) throws -> pid_t {
        #if canImport(Darwin)
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
        #else
            var actions = posix_spawn_file_actions_t()
            var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        if let input {
            posix_spawn_file_actions_adddup2(&actions, input, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, out, 1)
        posix_spawn_file_actions_adddup2(&actions, err, 2)
        posix_spawn_file_actions_addchdir_np(&actions, request.workingDirectory.path)

        // Its own process group, and SIGPIPE back to the default this process ignores.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))

        let argv = ([request.executable] + request.arguments).map { strdup($0) } + [nil]
        let envp = request.environment.keys.sorted().map { strdup("\($0)=\(request.environment[$0]!)") } + [nil]
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, request.executable, &actions, &attributes, argv, envp)
        guard code == 0 else {
            throw CadenceError.io("cannot run \(request.executable): \(String(cString: strerror(code)))")
        }
        return pid
    }

    /// A pipe whose ends close on exec, so only the ends `dup2` places in the child reach it.
    private static func pipe() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard Foundation.pipe(&fds) == 0 else { throw CadenceError.io("cannot create a pipe") }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
