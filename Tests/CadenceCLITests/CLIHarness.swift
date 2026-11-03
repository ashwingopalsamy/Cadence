import CadenceCore
import Foundation

/// Runs the built `cadence` binary against a throwaway CADENCE_HOME.
struct CLIRun {
    var status: Int32
    var stdout: String
    var stderr: String

    /// The single JSON object on stdout.
    func json() throws -> JSONValue {
        try JSONParser.parse(stdout.trimmingCharacters(in: .newlines))
    }
}

/// Finds the test bundle on platforms where `Bundle.main` is the test runner.
private final class BundleToken {}

struct CLIHome {
    let home: URL

    /// One folder per test process, removed when the process exits, so runs never leave homes behind in /tmp.
    static let root: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-cli-tests-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: CLIHome.root) }
        return root
    }()

    /// The pretend user home (`HOME`): `.claude`, `.claude.json` and `.local/bin` live here, never in the real one.
    let userHome: URL

    init() {
        let id = UUID().uuidString
        home = Self.root.appendingPathComponent("home-\(id)", isDirectory: true)
        userHome = Self.root.appendingPathComponent("user-\(id)", isDirectory: true)
    }

    var database: String { home.appendingPathComponent("cadence.db").path }
    var configFile: URL { home.appendingPathComponent("config.json") }

    /// The binary SwiftPM built next to the test bundle, for example `.build/debug/cadence`.
    /// On macOS `swift test` runs the bundle inside Xcode's `xctest` helper, so `Bundle.main` is the toolchain and
    /// the products folder has to come from the test bundle itself, or from the package's `.build` folder.
    static func binary() throws -> URL {
        var candidates: [URL] = []
        let testBundle = Bundle(for: BundleToken.self).bundleURL
        candidates.append(testBundle.deletingLastPathComponent().appendingPathComponent("cadence"))
        let bundle = Bundle.main.bundleURL
        candidates.append(bundle.deletingLastPathComponent().appendingPathComponent("cadence"))
        candidates.append(bundle.appendingPathComponent("Contents/MacOS/../../../cadence").standardized)
        if let first = ProcessInfo.processInfo.arguments.first {
            candidates.append(URL(fileURLWithPath: first).deletingLastPathComponent().appendingPathComponent("cadence"))
        }
        // Tests/CadenceCLITests/CLIHarness.swift -> the package root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(root.appendingPathComponent(".build/debug/cadence"))
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw HarnessError.binaryMissing(candidates.map(\.path))
    }

    @discardableResult
    func run(_ arguments: [String], environment extra: [String: String] = [:], stdin: String? = nil) throws -> CLIRun {
        let process = Process()
        process.executableURL = try Self.binary()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CADENCE_HOME"] = home.path
        // Every run acts on a throwaway user home, so doctor and setup never read or write the real one.
        environment["HOME"] = userHome.path
        environment["CADENCE_AGENT_LABEL"] = nil
        environment["CLAUDE_CONFIG_DIR"] = nil
        for (key, value) in extra { environment[key] = value }
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data((stdin ?? "").utf8))
        try? input.fileHandleForWriting.close()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CLIRun(
            status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Runs with `--json` and returns the parsed object. Fails the test if the command fails.
    func json(_ arguments: [String]) throws -> JSONValue {
        let result = try run(arguments + ["--json"])
        guard result.status == 0 else { throw HarnessError.failed(arguments, result.status, result.stderr) }
        return try result.json()
    }

    /// Today's date in the CLI's own view of the clock and zone.
    func today() throws -> LocalDate {
        let date = try json(["today"])["day"]?["date"]?.stringValue ?? ""
        guard let day = LocalDate(date) else { throw HarnessError.failed(["today"], 0, "no date in the result") }
        return day
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: userHome)
    }
}

struct WallClock: Clock {
    func now() -> Date { Date() }
}

enum HarnessError: Error, CustomStringConvertible {
    case binaryMissing([String])
    case failed([String], Int32, String)

    var description: String {
        switch self {
        case .binaryMissing(let looked):
            "the cadence binary was not found; run `swift build` first. Looked in: " + looked.joined(separator: ", ")
        case .failed(let args, let status, let stderr):
            "cadence \(args.joined(separator: " ")) exited \(status): \(stderr)"
        }
    }
}
