import Foundation
import Testing

@testable import CadenceCore

/// The FileVault line of `cadence doctor` (docs/SPEC.md section 13.1, docs/PLAN.md T1.22). The command runs through
/// the injected runner, so no test starts `fdesetup`. An answer that cannot be read is unknown, never on or off.
@Suite struct FileVaultCheckTests {
    let runner = RecordingRunner()

    func result(platform: HostPlatform = .macOS) -> AgentChecks.Result {
        FileVaultCheck(runner: runner, platform: platform, workingDirectory: TestStore.tempDirectory("filevault-home")).run()
    }

    @Test func offMacOSItIsNotApplicableAndNothingRuns() {
        let found = result(platform: .other)
        #expect(found == AgentChecks.Result(name: "filevault", level: .ok, detail: "not applicable on this system"))
        #expect(runner.requests.isEmpty)
    }

    @Test func fileVaultOnIsOk() throws {
        runner.answer(with: .success(.exited(0, stdout: "FileVault is On.\n")))
        let found = result()
        #expect(found == AgentChecks.Result(name: "filevault", level: .ok, detail: "FileVault is on, so the work log is encrypted at rest"))
        let request = try #require(runner.requests.first)
        #expect(request.executable == "/usr/bin/fdesetup")
        #expect(request.arguments == ["status"])
        #expect(request.environment["PATH"] == "/usr/bin:/bin")
        #expect(request.stdin == nil)
    }

    @Test func fileVaultOffWarnsAndSaysWhereToTurnItOn() {
        runner.answer(with: .success(.exited(0, stdout: "FileVault is Off.\n")))
        let found = result()
        #expect(found.name == "filevault")
        #expect(found.level == .warn)
        #expect(found.detail.hasPrefix("FileVault is off, so the work log is not encrypted at rest"))
        #expect(found.detail.contains("System Settings, Privacy & Security, FileVault"))
    }

    @Test func extraLinesAfterTheAnswerDoNotChangeIt() {
        runner.answer(with: .success(.exited(0, stdout: "FileVault is On.\nEncryption in progress: Percent completed = 12.\n")))
        #expect(result().level == .ok)
        runner.answer(with: .success(.exited(0, stdout: "FileVault is Off.\nDeferred enablement appears to be active for user 'someone'.\n")))
        #expect(result().detail.hasPrefix("FileVault is off"))
        // No final full stop, and a blank line first.
        runner.answer(with: .success(.exited(0, stdout: "\nFileVault is On\n")))
        #expect(result().level == .ok)
    }

    @Test func outputThatIsNeitherOnNorOffIsUnknown() {
        for text in [
            "", "\n", "FileVault is Maybe.\n", "FileVault is Online.\n", "Error: could not talk to the daemon\n",
            "filevault is on.\n", "not FileVault is On.\n", "FileVault is On and Off.\n", "On\n",
        ] {
            runner.answer(with: .success(.exited(0, stdout: text)))
            let found = result()
            #expect(found.level == .warn, "\(text.debugDescription)")
            #expect(found.detail.hasPrefix("unknown"), "\(text.debugDescription): \(found.detail)")
            #expect(!found.detail.contains("is on, so") && !found.detail.contains("is off, so"), "\(text.debugDescription)")
        }
    }

    @Test func aFailureIsUnknownEvenWhenTheOutputSaysOn() {
        runner.answer(with: .success(.exited(1, stdout: "FileVault is On.\n", stderr: "denied")))
        var found = result()
        #expect(found.level == .warn)
        #expect(found.detail.hasPrefix("unknown"))
        #expect(!found.detail.contains("denied"))  // stderr can hold anything; it is not copied into the report

        runner.answer(with: .success(.exited(0, stdout: "FileVault is On.\n", timedOut: true)))
        found = result()
        #expect(found.level == .warn)
        #expect(found.detail == "unknown, fdesetup did not answer in time")

        runner.answer(with: .success(ProcessResult(
            termination: .signalled(9), timedOut: false, stdout: Data("FileVault is On.\n".utf8), stdoutTruncated: false,
            stderrTail: Data())))
        #expect(result().detail.hasPrefix("unknown"))

        runner.answer(with: .failure(.io("cannot run /usr/bin/fdesetup")))
        found = result()
        #expect(found.level == .warn)
        #expect(found.detail == "unknown, fdesetup could not be run")
    }

    @Test func truncatedOutputIsUnknown() {
        runner.answer(with: .success(ProcessResult(
            termination: .exited(0), timedOut: false, stdout: Data("FileVault is On.\n".utf8), stdoutTruncated: true,
            stderrTail: Data())))
        #expect(result().detail.hasPrefix("unknown"))
    }

    @Test func detailsHaveNoDashes() {
        for text in ["FileVault is On.\n", "FileVault is Off.\n", "nonsense"] {
            runner.answer(with: .success(.exited(0, stdout: text)))
            let detail = result().detail
            #expect(!detail.contains("\u{2013}") && !detail.contains("\u{2014}"), "\(detail)")
        }
        #expect(!result(platform: .other).detail.contains("\u{2014}"))
    }
}
