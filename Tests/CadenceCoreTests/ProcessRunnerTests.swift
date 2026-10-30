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
}
