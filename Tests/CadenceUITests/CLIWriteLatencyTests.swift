import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The done-when of T3.5: a write by the real `cadence` binary reaches the model inside one second. The chain is
/// the real one, apart from the app shell: the CLI commits and posts the Darwin notification, the observer hears
/// it, the model reads the store off the main thread and publishes the new day. Both polls are an hour long, so
/// only the notification can make this fast. Everything lives in a temporary home.
@MainActor @Suite(.serialized) struct CLIWriteLatencyTests {
    struct WallClock: Clock {
        func now() -> Date { Date() }
    }

    final class BundleToken {}

    /// The `cadence` binary SwiftPM built next to the test bundle.
    nonisolated static func binary() throws -> URL {
        let bundle = Bundle(for: BundleToken.self).bundleURL
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            bundle.deletingLastPathComponent().appendingPathComponent("cadence"),
            root.appendingPathComponent(".build/debug/cadence"),
            root.appendingPathComponent(".build/out/Products/Debug/cadence"),
        ]
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw LatencyError.binaryMissing(candidates.map(\.path))
        }
        return found
    }

    enum LatencyError: Error { case binaryMissing([String]), failed(Int32, String) }

    /// Runs the CLI on a background thread, so the main actor stays free to hear the notification.
    nonisolated static func cli(_ arguments: [String], home: URL, userHome: URL) async throws {
        let executable = try binary()
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["CADENCE_HOME"] = home.path
            environment["HOME"] = userHome.path
            process.environment = environment
            let err = Pipe()
            process.standardError = err
            process.standardOutput = Pipe()
            try process.run()
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw LatencyError.failed(process.terminationStatus, message) }
        }.value
    }

    func until(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    @Test func aCLIWriteUpdatesTheModelWithinOneSecond() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-latency-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("store", isDirectory: true)
        let userHome = base.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // The first CLI run makes the store and plans one task.
        try await Self.cli(["plan", "add", "Review the ACME-101 change"], home: home, userHome: userHome)

        let roots = FileRoots(home: home)
        let clock = WallClock()
        let model = DayModel(loader: DayStoreLoader(location: .found(roots), clock: clock))
        let observer = StoreObserver(
            source: StoreVersionProbe(path: roots.database.path), clock: clock,
            timing: StoreWatchTiming(visiblePoll: 3600, hiddenPoll: 3600, coalesce: StoreWatchTiming.standard.coalesce),
            onChange: { Task { @MainActor in model.reload() } })
        observer.start()
        defer { observer.stop() }
        #expect(await until(timeout: .seconds(3)) { model.state?.planned == 1 })

        // The measured write: a new CLI process adds a second task.
        let started = ContinuousClock.now
        try await Self.cli(["plan", "add", "Write the release notes"], home: home, userHome: userHome)
        let cliExited = ContinuousClock.now
        let seen = await until(timeout: .seconds(2)) { model.state?.planned == 2 }
        let shown = ContinuousClock.now

        let total = started.duration(to: shown)
        let afterExit = cliExited.duration(to: shown)
        print("T3.5 measured: CLI write to model update \(total.milliseconds) ms (CLI process \(started.duration(to: cliExited).milliseconds) ms, commit to model \(afterExit.milliseconds) ms after the CLI exited)")
        #expect(seen)
        #expect(model.state?.tasks.map(\.title) == ["Review the ACME-101 change", "Write the release notes"])
        #expect(total < .seconds(1))
    }
}

extension Duration {
    fileprivate var milliseconds: Int {
        let parts = components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
