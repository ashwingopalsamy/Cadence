import Foundation
import Testing

@testable import CadenceCore

@Suite struct ProcessRunnerTests {
    let directory = FileManager.default.temporaryDirectory

    @Test func stdinReachesTheChildAndStdoutComesBack() throws {
        let request = ProcessRequest(
            executable: "/bin/cat", workingDirectory: directory, stdin: Data("Done\nNothing logged\n".utf8))
        #expect(request.stdin == Data("Done\nNothing logged\n".utf8))
        let result = try SystemProcessRunner().run(request)
        #expect(result.succeeded)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "Done\nNothing logged\n")
    }

    @Test func noStdinMeansNoInput() throws {
        #expect(ProcessRequest(executable: "/bin/cat", workingDirectory: directory).stdin == nil)
        let result = try SystemProcessRunner().run(ProcessRequest(executable: "/bin/cat", workingDirectory: directory))
        #expect(result.succeeded && result.stdout.isEmpty)
    }

    @Test func limitsAndExitStatusAreReported() throws {
        let big = Data(repeating: 0x61, count: 100_000)
        let capped = try SystemProcessRunner().run(
            ProcessRequest(executable: "/bin/cat", workingDirectory: directory, stdin: big, stdoutLimit: 1000))
        #expect(capped.stdout.count == 1000 && capped.stdoutTruncated)
        let failed = try SystemProcessRunner().run(
            ProcessRequest(executable: "/bin/sh", arguments: ["-c", "exit 3"], workingDirectory: directory))
        #expect(failed.termination == .exited(3) && !failed.succeeded)
    }

    @Test func aSlowChildIsStoppedAtTheTimeout() throws {
        let result = try SystemProcessRunner().run(
            ProcessRequest(
                executable: "/bin/sleep", arguments: ["30"], workingDirectory: directory, timeout: .milliseconds(200),
                killGrace: .milliseconds(200)))
        #expect(result.timedOut && !result.succeeded)
    }

    @Test func aRelativeExecutableIsRefused() {
        #expect(throws: CadenceError.self) {
            try SystemProcessRunner().run(ProcessRequest(executable: "cat", workingDirectory: directory))
        }
    }

    func timed(_ script: String, timeout: Duration = .seconds(1)) throws -> (ProcessResult, Double) {
        let start = Date()
        let result = try SystemProcessRunner().run(
            ProcessRequest(executable: "/bin/sh", arguments: ["-c", script], workingDirectory: directory, timeout: timeout,
                           killGrace: .milliseconds(300)))
        return (result, Date().timeIntervalSince(start))
    }

    @Test func theTimeoutReachesEverythingTheCommandStarted() throws {
        let (result, elapsed) = try timed("sleep 8; echo late")
        #expect(result.timedOut && elapsed < 4, "took \(elapsed) s")
        #expect(result.stdout.isEmpty)
    }

    @Test func aCommandThatIgnoresSIGTERMIsKilled() throws {
        let (result, elapsed) = try timed("trap '' TERM; sleep 8")
        #expect(result.timedOut && elapsed < 4, "took \(elapsed) s")
    }

    @Test func aBackgroundChildCannotHoldTheRunOpen() throws {
        let (result, elapsed) = try timed("sleep 8 & echo hi", timeout: .seconds(30))
        #expect(!result.timedOut && result.termination == .exited(0) && elapsed < 4, "took \(elapsed) s")
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hi\n")
    }

    @Test func theEnvironmentAndFolderAreExactlyAsGiven() throws {
        let result = try SystemProcessRunner().run(
            ProcessRequest(executable: "/bin/sh", arguments: ["-c", "env | sort; pwd -P"], environment: ["A_KEY": "one two", "PATH": "/usr/bin:/bin"],
                           workingDirectory: URL(fileURLWithPath: "/")))
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.contains("A_KEY=one two") && lines.contains("PATH=/usr/bin:/bin") && lines.last == "/")
        #expect(!lines.contains { $0.hasPrefix("HOME=") })
    }

    @Test func theStderrTailKeepsTheLastBytes() throws {
        let result = try SystemProcessRunner().run(
            ProcessRequest(executable: "/bin/sh", arguments: ["-c", "head -c 100000 /dev/zero | tr '\\0' e >&2; printf END >&2"],
                           workingDirectory: directory, stderrTailLimit: 64 * 1024))
        #expect(result.stderrTail.count == 64 * 1024)
        #expect(String(decoding: result.stderrTail.suffix(3), as: UTF8.self) == "END")
    }

    @Test func aMissingExecutableIsAReadableError() {
        #expect(throws: CadenceError.self) {
            try SystemProcessRunner().run(ProcessRequest(executable: "/nonexistent/collector", workingDirectory: directory))
        }
    }
}
