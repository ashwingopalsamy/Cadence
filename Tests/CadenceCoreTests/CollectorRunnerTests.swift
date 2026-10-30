import Foundation
import Testing

@testable import CadenceCore

/// docs/SPEC.md section 10.2. The clock reads Monday 2026-09-21 19:43 in Kolkata.
@Suite struct CollectorRunnerTests {
    static let window = IngestWindow(since: "2026-09-18", until: "2026-09-21")

    /// Records every request and answers with a canned result.
    final class FakeRunner: ProcessRunner, @unchecked Sendable {
        var requests: [ProcessRequest] = []
        var result: ProcessResult

        init(_ result: ProcessResult) { self.result = result }

        func run(_ request: ProcessRequest) throws -> ProcessResult {
            requests.append(request)
            return result
        }
    }

    static func output(_ text: String, status: Int32 = 0, stderr: String = "", timedOut: Bool = false, truncated: Bool = false) -> ProcessResult {
        ProcessResult(
            termination: .exited(status), timedOut: timedOut, stdout: Data(text.utf8), stdoutTruncated: truncated,
            stderrTail: Data(stderr.utf8))
    }

    static func envelope(_ collector: String = "oncall") -> String {
        [
            #"{"cadence":"envelope/1","collector":"\#(collector)","run":"r1","generated_at":"2026-09-21T16:10:02+05:30","window":{"since":"2026-09-18","until":"2026-09-21"}}"#,
            #"{"type":"item","source_ref":"oncall:2026-09-21","kind":"oncall.shift","day":"2026-09-21","title":"On call (primary)"}"#,
        ].joined(separator: "\n") + "\n"
    }

    struct Fixture {
        let roots = FileRoots(home: TestStore.tempDirectory())
        let clock = ManualClock(TestStore.start)
        let store: SQLiteStore
        let journal: Journal

        init(collectors: [Config.Collector], configMode: Int? = 0o600) throws {
            var config = Config.defaults(timezone: "Asia/Kolkata")
            config.collectors = collectors
            store = try TestStore.make(path: roots.database.path, clock: clock, projector: LedgerProjector())
            journal = try Journal(store: store, config: config, clock: clock, ids: CountingIDs())
            if let configMode {
                try Data("{}".utf8).write(to: roots.config)
                try FileManager.default.setAttributes([.posixPermissions: configMode], ofItemAtPath: roots.config.path)
            }
        }

        func runner(_ process: any ProcessRunner, environment: [String: String] = ["HOME": "/home/sample", "SECRET_TOKEN": "x"])
            -> CollectorRunner
        {
            CollectorRunner(roots: roots, journal: journal, runner: process, selfExecutable: "/opt/cadence/bin/cadence", environment: environment)
        }

        func approveAll(_ runner: CollectorRunner) throws {
            for collector in journal.config.collectors {
                try runner.approve(try CollectorRunner.plan(for: collector, selfExecutable: "/opt/cadence/bin/cadence"))
            }
        }

        func runs() throws -> [IngestRun] {
            try store.events(after: 0, limit: 10_000).filter { $0.type == "ingest.run" }.map { try IngestRun(json: $0.data) }
        }

        func report(_ result: CollectorRunResult) throws -> IngestReport {
            guard case .ran(let report) = result else {
                Issue.record("expected a run, got \(result)")
                throw CadenceError.validation("not run")
            }
            return report
        }
    }

    static let oncall = Config.Collector(name: "oncall", command: ["/bin/sh", "/opt/collectors/oncall.sh", "{since}", "{until}"], env: ["ROTA": "primary"])

    // MARK: - Approval

    @Test func anUnapprovedCommandIsRefusedAndNothingRuns() throws {
        let f = try Fixture(collectors: [Self.oncall])
        let fake = FakeRunner(Self.output(Self.envelope()))
        let result = try f.runner(fake).run(name: "oncall", window: Self.window)
        #expect(result == .refused(.notApproved))
        #expect(fake.requests.isEmpty)
        #expect(try f.runs().isEmpty)
    }

    @Test func anApprovedCommandRunsAndItsEnvelopeIsIngested() throws {
        let f = try Fixture(collectors: [Self.oncall])
        let fake = FakeRunner(Self.output(Self.envelope()))
        let runner = f.runner(fake)
        try f.approveAll(runner)
        let report = try f.report(try runner.run(name: "oncall", window: Self.window))
        #expect(report.status == "ok" && report.count("created") == 1)
        let entry = try #require(try f.journal.query(EntryQuery(from: LocalDate("2026-09-21")!, to: LocalDate("2026-09-21")!)).entries.first)
        #expect(entry.origin == .collected && entry.source == "oncall")
        let mode = try FileManager.default.attributesOfItem(atPath: runner.approvalsFile.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func aChangedCommandOrEnvironmentNeedsApprovalAgain() throws {
        let f = try Fixture(collectors: [Self.oncall])
        let runner = f.runner(FakeRunner(Self.output(Self.envelope())))
        let approved = try CollectorRunner.plan(for: Self.oncall, selfExecutable: "/x")
        try runner.approve(approved)
        var argv = Self.oncall
        argv.command = ["/bin/sh", "/opt/collectors/oncall.sh", "{since}", "{until}", "--all"]
        #expect(!runner.isApproved(try CollectorRunner.plan(for: argv, selfExecutable: "/x")))
        var env = Self.oncall
        env.env["ROTA"] = "secondary"
        #expect(!runner.isApproved(try CollectorRunner.plan(for: env, selfExecutable: "/x")))
        #expect(runner.isApproved(approved))
    }

    @Test func approvalsInAFileOthersCanWriteAreNotTrusted() throws {
        let f = try Fixture(collectors: [Self.oncall])
        let runner = f.runner(FakeRunner(Self.output(Self.envelope())))
        try f.approveAll(runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: runner.approvalsFile.path)
        #expect(try runner.run(name: "oncall", window: Self.window) == .refused(.notApproved))
    }

    @Test func theApprovalPromptShowsEveryArgumentAndTheEnvironment() throws {
        let plan = try CollectorRunner.plan(for: Self.oncall, selfExecutable: "/x")
        #expect(plan.approvalText == """
            Collector oncall will run:
              /bin/sh
              /opt/collectors/oncall.sh
              {since}
              {until}
            with this environment:
              ROTA=primary
            """)
    }

    // MARK: - Config safety and state

    @Test func aConfigOthersCanReadTurnsCollectorsOff() throws {
        let open = try Fixture(collectors: [Self.oncall], configMode: 0o644)
        let fake = FakeRunner(Self.output(Self.envelope()))
        let runner = open.runner(fake)
        try open.approveAll(runner)
        #expect(try runner.run(name: "oncall", window: Self.window) == .refused(.unsafeConfig("config.json has mode 644; it must be 600")))
        #expect(fake.requests.isEmpty)

        let missing = try Fixture(collectors: [Self.oncall], configMode: nil)
        #expect(try missing.runner(fake).run(name: "oncall", window: Self.window) == .refused(.unsafeConfig("config.json does not exist")))
    }

    @Test func unknownAndDisabledCollectorsAreRefused() throws {
        var off = Self.oncall
        off.enabled = false
        let f = try Fixture(collectors: [off])
        let runner = f.runner(FakeRunner(Self.output(Self.envelope())))
        #expect(try runner.run(name: "oncall", window: Self.window) == .refused(.disabled))
        #expect(try runner.run(name: "missing", window: Self.window) == .refused(.unknown("missing")))
    }

    @Test func oneRunPerCollectorAtATime() throws {
        let f = try Fixture(collectors: [Self.oncall])
        let fake = FakeRunner(Self.output(Self.envelope()))
        let runner = f.runner(fake)
        try f.approveAll(runner)
        let held = try #require(try RunLock(f.roots.state.appendingPathComponent("locks/oncall.lock")))
        #expect(try runner.run(name: "oncall", window: Self.window) == .refused(.alreadyRunning))
        held.release()
        #expect(try f.report(try runner.run(name: "oncall", window: Self.window)).status == "ok")
    }

    // MARK: - Execution

    @Test func argvEnvironmentAndLimitsAreExactlyAsSpecified() throws {
        let f = try Fixture(collectors: [Config.Collector(
            name: "oncall", command: ["/bin/sh", "/opt/collectors/oncall.sh", "--from={since}", "{until}"], env: ["ROTA": "{since}"])])
        let fake = FakeRunner(Self.output(Self.envelope()))
        let runner = f.runner(fake)
        try f.approveAll(runner)
        _ = try runner.run(name: "oncall", window: Self.window)
        let request = try #require(fake.requests.first)
        #expect(request.executable == "/bin/sh")
        #expect(request.arguments == ["/opt/collectors/oncall.sh", "--from=2026-09-18", "2026-09-21"])
        #expect(request.environment == [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/home/sample", "LANG": "en_US.UTF-8", "TZ": "Asia/Kolkata",
            "ROTA": "{since}",
        ])
        #expect(request.stdin == nil)
        #expect(request.workingDirectory == f.roots.home)
        #expect(request.timeout == .seconds(60) && request.killGrace == .seconds(5))
        #expect(request.stdoutLimit == 10 * 1024 * 1024 && request.stderrTailLimit == 64 * 1024)
    }

    @Test func shellMetacharactersStayInert() throws {
        let marker = TestStore.tempDirectory().appendingPathComponent("pwned")
        let hostile = "$(touch \(marker.path)); `touch \(marker.path)` | touch \(marker.path) && echo {since}"
        let f = try Fixture(collectors: [Config.Collector(name: "echo", command: ["/usr/bin/printf", "%s", hostile])])
        let runner = f.runner(SystemProcessRunner())
        try f.approveAll(runner)
        let report = try f.report(try runner.run(name: "echo", window: Self.window))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        // printf printed the argument back verbatim, which is not an envelope header.
        #expect(report.status == "error")
        let kept = try #require(report.inbox)
        let printed = try String(contentsOf: kept, encoding: .utf8)
        #expect(printed == hostile.replacingOccurrences(of: "{since}", with: "2026-09-18"))
    }

    @Test func aRealScriptRunsEndToEnd() throws {
        let script = TestStore.tempDirectory().appendingPathComponent("oncall.sh")
        try Data("""
            printf '{"cadence":"envelope/1","collector":"oncall","run":"r1","generated_at":"2026-09-21T16:10:02+05:30","window":{"since":"%s","until":"%s"}}\\n' "$1" "$2"
            printf '{"type":"item","source_ref":"oncall:%s","kind":"oncall.shift","day":"%s","title":"On call (%s)"}\\n' "$2" "$2" "$ROTA"
            echo "done" >&2

            """.utf8).write(to: script)
        let f = try Fixture(collectors: [Config.Collector(name: "oncall", command: ["/bin/sh", script.path, "{since}", "{until}"], env: ["ROTA": "primary"])])
        let runner = f.runner(SystemProcessRunner())
        try f.approveAll(runner)
        let report = try f.report(try runner.run(name: "oncall", window: Self.window))
        #expect(report.status == "ok" && report.count("created") == 1, "\(report.problems)")
        let log = try String(contentsOf: f.roots.logs.appendingPathComponent("collector-oncall.log"), encoding: .utf8)
        #expect(log.hasSuffix("done\n"))
        let mode = try FileManager.default.attributesOfItem(atPath: f.roots.logs.appendingPathComponent("collector-oncall.log").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func failuresWriteOnlyAFailedIngestRun() throws {
        let cases: [(ProcessResult, String)] = [
            (Self.output(Self.envelope(), status: 2, stderr: "warming up\ngh: not logged in\n"), "exit status 2: gh: not logged in"),
            (Self.output(Self.envelope(), timedOut: true), "timed out after 60 s"),
            (Self.output(Self.envelope(), truncated: true), "output was larger than 10 MB and was cut"),
            (ProcessResult(termination: .signalled(9), timedOut: false, stdout: Data(), stdoutTruncated: false, stderrTail: Data()), "stopped by signal 9"),
        ]
        for (result, message) in cases {
            let f = try Fixture(collectors: [Self.oncall])
            let runner = f.runner(FakeRunner(result))
            try f.approveAll(runner)
            let report = try f.report(try runner.run(name: "oncall", window: Self.window))
            #expect(report.status == "error")
            let runs = try f.runs()
            #expect(runs.count == 1 && runs[0].status == "error" && runs[0].errors == [message])
            #expect(try f.store.events(after: 0, limit: 100).filter { $0.type == "entry.created" }.isEmpty)
        }
    }

    @Test func aMapCollectorNeedsTheMapEngine() throws {
        var mapped = Self.oncall
        mapped.map = "usage.map.json"
        let f = try Fixture(collectors: [mapped])
        let runner = f.runner(FakeRunner(Self.output("[]")))
        try f.approveAll(runner)
        let report = try f.report(try runner.run(name: "oncall", window: Self.window))
        #expect(report.status == "error" && report.problems == ["map collectors need map/1"])
    }

    @Test func aMapCollectorsOutputIsMappedAndBadRowsAreCounted() throws {
        var mapped = Config.Collector(name: "endpoint", command: ["/usr/bin/curl", "-s", "https://usage.example.com/daily?from={since}"])
        mapped.map = "endpoint.json"
        let f = try Fixture(collectors: [mapped])
        try FileManager.default.createDirectory(at: f.roots.maps, withIntermediateDirectories: true)
        try Data(MapEngineTests.endpointMap.utf8).write(to: f.roots.maps.appendingPathComponent("endpoint.json"))
        let body = #"{"data":[{"date":"2026-09-18","model":"model-a","output_tokens":9,"cost_usd":0.4213},{"date":"2026-09-18","model":"model-b","output_tokens":-1}]}"#
        let runner = CollectorRunner(
            roots: f.roots, journal: f.journal, runner: FakeRunner(Self.output(body)), selfExecutable: "/x", environment: [:],
            transform: MapTransform(roots: f.roots, zone: f.journal.zone, boundary: f.journal.config.dayBoundary, clock: f.clock, ids: CountingIDs()))
        try f.approveAll(runner)
        let report = try f.report(try runner.run(name: "endpoint", window: Self.window))
        #expect(report.count("created") == 1 && report.count("skipped") == 1 && report.count("records") == 2)
        #expect(report.problems == ["map: record 2: tokens.out: must not be negative"])
        #expect(report.inbox != nil)
        let row = try #require(try f.store.db.query("SELECT * FROM genai_usage").first)
        #expect(row.int("cost_micros") == 421_300 && row.text("source") == "endpoint")
    }

    @Test func aBadWindowIsRefused() throws {
        let f = try Fixture(collectors: [Self.oncall])
        #expect(throws: CadenceError.self) {
            try f.runner(FakeRunner(Self.output(""))).run(name: "oncall", window: IngestWindow(since: "yesterday; rm", until: "2026-09-21"))
        }
    }

    // MARK: - Plans

    @Test func builtinsRunThisBinaryAndCommandsMustBeAbsolute() throws {
        let github = try CollectorRunner.plan(
            for: Config.Collector(name: "github", builtin: "github", env: ["GH_HOST": "git.example.com"], gh: "/opt/homebrew/bin/gh"),
            selfExecutable: "/opt/cadence/bin/cadence")
        #expect(github.executable == "/opt/cadence/bin/cadence")
        #expect(github.arguments == ["collector", "github", "--since", "{since}", "--until", "{until}", "--name", "github", "--gh", "/opt/homebrew/bin/gh"])
        let transcripts = try CollectorRunner.plan(
            for: Config.Collector(name: "claude-code", builtin: "claude-code-transcripts"), selfExecutable: "/opt/cadence/bin/cadence")
        #expect(transcripts.arguments == ["collector", "claude-code-transcripts", "--since", "{since}", "--until", "{until}", "--name", "claude-code"])
        #expect(throws: CadenceError.self) {
            try CollectorRunner.plan(for: Config.Collector(name: "rel", command: ["oncall.sh"]), selfExecutable: "/x")
        }
        #expect(throws: CadenceError.self) {
            try CollectorRunner.plan(for: Config.Collector(name: "path", command: ["/bin/sh"], env: ["PATH": "/tmp"]), selfExecutable: "/x")
        }
    }

    // MARK: - Health

    @Test func theErrorStateNeedsThreeFailuresInARow() throws {
        let f = try Fixture(collectors: [Self.oncall])
        let fake = FakeRunner(Self.output("", status: 1))
        let runner = f.runner(fake)
        try f.approveAll(runner)
        #expect(try runner.health(name: "oncall") == CollectorHealth(failuresInARow: 0, lastError: nil))
        _ = try runner.run(name: "oncall", window: Self.window)
        _ = try runner.run(name: "oncall", window: Self.window)
        #expect(try !runner.health(name: "oncall").isFailing)
        _ = try runner.run(name: "oncall", window: Self.window)
        let failing = try runner.health(name: "oncall")
        #expect(failing.isFailing && failing.failuresInARow == 3 && failing.lastError == "exit status 1")
        fake.result = Self.output(Self.envelope())
        _ = try runner.run(name: "oncall", window: Self.window)
        #expect(try runner.health(name: "oncall").failuresInARow == 0)
    }
}
