import Foundation
import Testing

@testable import CadenceCore

/// The shipped examples run (docs/PLAN.md T2.16): the example config loads, every sample map maps its sample input,
/// and the on-call collector prints an envelope the reader accepts, from the shell and from the Python twin.
@Suite struct ExamplesTests {
    /// examples/ in the repo, located from this file's path.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CadenceCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // the repo root
        .appendingPathComponent("examples", isDirectory: true)

    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    /// Later than every sample day, so no record is in the future.
    static let now = Timestamp.parse("2026-10-30T12:00:00+05:30")!
    static let generatedAt = Timestamp.parse("2026-10-30T06:30:00Z")!
    static let window = IngestWindow(since: "2026-10-26", until: "2026-10-29")
    static let windowArguments = ["--since", "2026-10-26", "--until", "2026-10-29"]

    static func bytes(_ relativePath: String) throws -> [UInt8] {
        Array(try Data(contentsOf: root.appendingPathComponent(relativePath)))
    }

    static func script(_ name: String) -> String {
        root.appendingPathComponent("collectors/\(name)").path
    }

    /// Reads an envelope as ingest does: the header must name the collector, then every record line is parsed.
    static func readLines(_ bytes: [UInt8], collector: String) throws -> [EnvelopeLine] {
        let parts = try EnvelopeReader.split(bytes)
        _ = try EnvelopeReader.header(parts.header.1, collector: collector)
        let reader = EnvelopeReader(context: EnvelopeContext(
            now: now, zone: zone, boundary: .standard, classifier: try TicketClassifier(rules: .standard), httpHosts: []))
        return parts.records.map { reader.line($0.0, $0.1) }
    }

    /// What the reader refused, one line per record. Empty when every record is accepted.
    static func refusals(_ lines: [EnvelopeLine]) -> [String] {
        lines.compactMap { line in
            guard case .failure(let error) = line.record else { return nil }
            return "line \(line.number): \(error.message)"
        }
    }

    /// Ingests an envelope into a new ledger, as the runner does.
    static func ingest(_ bytes: [UInt8], collector: String) throws -> IngestReport {
        let clock = ManualClock(now)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        let journal = try Journal(store: store, config: Config.defaults(timezone: "Asia/Kolkata"), clock: clock, ids: CountingIDs())
        return try journal.ingest(envelope: bytes, collector: collector, window: window)
    }

    /// Runs a command the way the collector runner does: argv, a fixed environment and nothing inherited.
    static func runCollector(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let home = TestStore.tempDirectory()
        let shifts = root.appendingPathComponent("collectors/oncall-shifts.csv").path
        let environment = [
            "PATH": "/usr/bin:/bin", "HOME": home.path, "LANG": "en_US.UTF-8", "TZ": "Asia/Kolkata", "ONCALL_SHIFTS": shifts,
        ]
        return try SystemProcessRunner().run(ProcessRequest(
            executable: executable, arguments: arguments, environment: environment, workingDirectory: home))
    }

    /// The record lines of an envelope, without the header: the header carries a run ID and a time, which differ.
    static func recordLines(_ bytes: [UInt8]) -> [String] {
        String(decoding: bytes, as: UTF8.self).split(separator: "\n").dropFirst().map(String.init)
    }

    @Test func theExampleConfigLoads() throws {
        let config = try Config.parse(bytes: try Self.bytes("config.example.json"))
        #expect(config.profile.timezone == "Asia/Kolkata")
        #expect(config.collectors.map(\.name) == ["claude-code", "genai-endpoint", "github"])
        // A map a collector names must be one of the shipped maps.
        for collector in config.collectors {
            guard let map = collector.map else { continue }
            #expect(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(map).path), "\(map)")
        }
    }

    @Test func everySampleMapMapsItsSampleInput() throws {
        let maps = try FileManager.default.contentsOfDirectory(
            at: Self.root.appendingPathComponent("maps"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(maps.map(\.lastPathComponent) == ["genai-endpoint.json", "oncall-roster.json", "usage-export.json"])
        for file in maps {
            let name = file.deletingPathExtension().lastPathComponent
            let map = try MapFile(bytes: Array(try Data(contentsOf: file)), name: name)
            let sample = try Self.bytes("maps/samples/\(name).\(map.input.rawValue)")
            let output = try MapEngine(map: map, zone: Self.zone, boundary: .standard).envelope(
                from: sample, collector: name, window: Self.window, run: "examples", generatedAt: Self.generatedAt)
            #expect(output.skipped.isEmpty, "\(name): \(output.skipped)")
            #expect(output.records > 0, "\(name)")
            let lines = try Self.readLines(output.envelope, collector: name)
            #expect(Self.refusals(lines).isEmpty, "\(name): \(Self.refusals(lines))")
            let report = try Self.ingest(output.envelope, collector: name)
            #expect(
                report.count("created") == Int64(output.records) && report.count("skipped") == 0,
                "\(name): \(report.problems)")
        }
    }

    @Test func theShellCollectorPrintsAnEnvelopeTheReaderAccepts() throws {
        // /bin/sh is on every Mac and Linux host; the guard keeps the test honest where it is not.
        guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else { return }
        let result = try Self.runCollector("/bin/sh", [Self.script("oncall.sh")] + Self.windowArguments)
        #expect(result.succeeded, "\(result.termination): \(String(decoding: result.stderrTail, as: UTF8.self))")
        let bytes = Array(result.stdout)
        let lines = try Self.readLines(bytes, collector: "oncall")
        #expect(Self.refusals(lines).isEmpty, "\(Self.refusals(lines))")
        let refs = lines.compactMap { line -> String? in
            guard case .success(.item(let item)) = line.record else { return nil }
            return item.sourceRef
        }
        // Shifts before the window and after it are left out; both ends of the window are in.
        #expect(refs == [
            "oncall:2026-10-26:primary", "oncall:2026-10-27:secondary", "oncall:2026-10-28:primary", "oncall:2026-10-29:primary",
        ])
        #expect(try Self.ingest(bytes, collector: "oncall").count("created") == 4)
    }

    @Test func thePythonTwinPrintsTheSameRecords() throws {
        // Python 3 is optional here: the shell collector is checked above either way.
        guard let python = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return }
        let shell = try Self.runCollector("/bin/sh", [Self.script("oncall.sh")] + Self.windowArguments)
        let twin = try Self.runCollector(python, ["-I", Self.script("oncall.py")] + Self.windowArguments)
        #expect(twin.succeeded, "\(twin.termination): \(String(decoding: twin.stderrTail, as: UTF8.self))")
        #expect(Self.recordLines(Array(twin.stdout)) == Self.recordLines(Array(shell.stdout)))
        #expect(Self.refusals(try Self.readLines(Array(twin.stdout), collector: "oncall")).isEmpty)
    }

    @Test func theShellCollectorRefusesAWindowItCannotRead() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else { return }
        let result = try Self.runCollector("/bin/sh", [Self.script("oncall.sh"), "--since", "last week", "--until", "2026-10-29"])
        #expect(result.termination == .exited(1))
        #expect(result.stdout.isEmpty)
    }
}
