import Foundation
import Testing

@testable import CadenceCore

@Suite struct HookTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21T14:13:20Z

    static let startInput = """
        {"session_id":"abc-123","transcript_path":"/home/sample/.claude/projects/p/abc.jsonl","cwd":"/home/sample/work/acme-service",\
        "hook_event_name":"SessionStart","source":"startup","model":"model-a","prompt":"SECRET PROMPT TEXT",\
        "tool_input":{"command":"cat /etc/secret","timeout":1.5}}
        """

    func tempHome() -> FileRoots { FileRoots(home: TestStore.tempDirectory()) }

    func lines(_ roots: FileRoots) throws -> [String] {
        let file = HookSpool.fileURL(in: roots.spool, now: Self.now)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    @Test func keepsOnlyAllowlistedFields() throws {
        let line = try #require(HookSpool.line(event: .sessionStart, input: Array(Self.startInput.utf8), now: Self.now))
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        #expect(
            text
                == #"{"at":"2026-09-21T14:13:20.000Z","event":"session-start","model":"model-a","project":"acme-service","session_id":"abc-123","source":"startup","v":1}"#
                + "\n")
        for forbidden in ["SECRET", "transcript", "/home/sample", "tool_input", "/etc/secret"] {
            #expect(!text.contains(forbidden))
        }
    }

    @Test func sessionEndKeepsTheReasonOnly() throws {
        let input = #"{"session_id":"abc-123","cwd":"/","reason":"clear","transcript_path":"/x/y.jsonl"}"#
        let line = try #require(HookSpool.line(event: .sessionEnd, input: Array(input.utf8), now: Self.now))
        let object = try #require(try JSONParser.parse(bytes: Array(line.dropLast())).objectValue)
        #expect(Set(object.keys) == ["v", "event", "at", "session_id", "reason"])
        #expect(object["reason"]?.stringValue == "clear")
    }

    @Test func taskCompletedKeepsAnIdAtMost() throws {
        let input = #"{"session_id":"s1","task_id":"t-9","task_subject":"private words","cwd":"/a/b"}"#
        let line = try #require(HookSpool.line(event: .taskCompleted, input: Array(input.utf8), now: Self.now))
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.contains(#""task_id":"t-9""#))
        #expect(!text.contains("private"))
    }

    @Test func aliasIsTheFolderNameOnly() {
        #expect(HookSpool.projectAlias(cwd: "/home/sample/work/acme-service/") == "acme-service")
        #expect(HookSpool.projectAlias(cwd: "C:\\Users\\sample\\acme") == "acme")
        #expect(HookSpool.projectAlias(cwd: "/") == nil)
        #expect(HookSpool.projectAlias(cwd: "") == nil)
        #expect(HookSpool.projectAlias(cwd: "/a/bad\nname") == "badname")
    }

    @Test func malformedInputWritesNothing() throws {
        let roots = tempHome()
        for input in ["", "not json", "[]", "{}", #"{"session_id":7}"#, #"{"session_id":""}"#, #"{"session_id":"a b"}"#, #"{"session_id":"../x"}"#] {
            let result = HookRunner.run(event: "session-end", input: Array(input.utf8), spool: roots.spool, now: Self.now, plan: nil)
            #expect(result.stdout == nil)
            #expect(result.warning != nil)
        }
        #expect(try lines(roots).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: HookSpool.fileURL(in: roots.spool, now: Self.now).path))
    }

    @Test func unknownEventWritesNothing() throws {
        let roots = tempHome()
        let result = HookRunner.run(event: "pre-tool-use", input: Array(Self.startInput.utf8), spool: roots.spool, now: Self.now, plan: nil)
        #expect(result.warning != nil)
        #expect(try lines(roots).isEmpty)
    }

    @Test func appendsOneLinePerCallWithPrivateModes() throws {
        let roots = tempHome()
        for _ in 0..<3 {
            let result = HookRunner.run(event: "session-start", input: Array(Self.startInput.utf8), spool: roots.spool, now: Self.now, plan: nil)
            #expect(result.warning == nil)
        }
        #expect(try lines(roots).count == 3)
        let file = HookSpool.fileURL(in: roots.spool, now: Self.now)
        #expect(file.lastPathComponent == "hooks-2026-09-21.ndjson")
        let fileMode = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        let folderMode = try #require(FileManager.default.attributesOfItem(atPath: roots.spool.path)[.posixPermissions] as? NSNumber)
        #expect(fileMode.intValue & 0o777 == 0o600)
        #expect(folderMode.intValue & 0o777 == 0o700)
    }

    // MARK: no SQLite on the spool path

    @Test func theSpoolPathSucceedsWhenTheDatabaseIsUnusable() throws {
        let roots = tempHome()
        try FileManager.default.createDirectory(at: roots.database, withIntermediateDirectories: true)
        let marker = roots.database.appendingPathComponent("marker")
        try Data("untouched".utf8).write(to: marker)

        let result = HookRunner.run(event: "session-end", input: Array(#"{"session_id":"s1","reason":"other"}"#.utf8), spool: roots.spool, now: Self.now, plan: nil)
        #expect(result.warning == nil)
        #expect(try lines(roots).count == 1)

        // SessionStart reads the store after the write; a database that cannot be opened prints nothing.
        let start = HookRunner.run(
            event: "session-start", input: Array(Self.startInput.utf8), spool: roots.spool, now: Self.now,
            plan: { HookPlan.contextLine(roots: roots, clock: ManualClock(Self.now)) })
        #expect(start.stdout == nil)
        #expect(start.warning == nil)
        #expect(try lines(roots).count == 2)
        #expect(try Data(contentsOf: marker) == Data("untouched".utf8))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: roots.database.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: roots.database.path) == ["marker"])
    }

    @Test func theSpoolPathDoesNotCallThePlanReaderOutsideSessionStart() throws {
        let roots = tempHome()
        for name in ["session-end", "stop", "task-completed"] {
            let result = HookRunner.run(
                event: name, input: Array(#"{"session_id":"s1"}"#.utf8), spool: roots.spool, now: Self.now,
                plan: { Issue.record("the plan reader ran for \(name)"); return "x" })
            #expect(result.stdout == nil)
        }
        #expect(try lines(roots).count == 3)
    }

    @Test func theHookSourceDoesNotReferenceTheStore() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CadenceCore/Spool/HookSpool.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for word in ["SQLite", "sqlite", "Journal", "Projector", "ConfigStore"] {
            #expect(!text.contains(word), "HookSpool.swift mentions \(word)")
        }
    }

    // MARK: plan at SessionStart

    @Test func sessionStartPrintsTodaysPlanFromAReadOnlyStore() throws {
        let roots = tempHome()
        let clock = ManualClock(TestStore.start)  // Monday 2026-09-21, 19:43 in Kolkata
        let store = try TestStore.make(path: roots.database.path, clock: clock, projector: LedgerProjector())
        let journal = try Journal(store: store, config: Config.defaults(timezone: "Asia/Kolkata"), clock: clock, ids: CountingIDs())
        let first = try journal.planAdd(title: "Retry budget rollout", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        for title in ["Idempotency ADR", "Review ACME-482913", "Write the RFC"] {
            _ = try journal.planAdd(title: title, day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        }
        _ = try journal.planResolve(taskID: first.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        _ = try journal.planAdd(title: "Tomorrow only", day: journal.today().adding(days: 1), estimateMin: nil, origin: .selfReported, actor: .cli)

        let before = try Data(contentsOf: roots.database)
        let line = HookPlan.contextLine(roots: roots, clock: clock)
        #expect(line == "Cadence plan for Mon 21 Sep, 1 of 4 done: Idempotency ADR; Review ACME-482913; Write the RFC")
        #expect(try Data(contentsOf: roots.database) == before)
    }

    @Test func theLineTruncatesAfterThreeOpenTasksAndHonoursTheSwitch() throws {
        let roots = tempHome()
        let clock = ManualClock(TestStore.start)
        let store = try TestStore.make(path: roots.database.path, clock: clock, projector: LedgerProjector())
        let journal = try Journal(store: store, config: Config.defaults(timezone: "Asia/Kolkata"), clock: clock, ids: CountingIDs())
        for n in 1...5 { _ = try journal.planAdd(title: "Task \(n)", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli) }
        #expect(HookPlan.contextLine(roots: roots, clock: clock) == "Cadence plan for Mon 21 Sep, 0 of 5 done: Task 1; Task 2; Task 3; …")

        var config = Config.defaults(timezone: "Asia/Kolkata")
        config.claudeCode.injectPlanAtSessionStart = false
        try ConfigStore.save(config, to: roots.config)
        #expect(HookPlan.contextLine(roots: roots, clock: clock) == nil)
    }

    @Test func noPlanMeansNoOutput() throws {
        let roots = tempHome()
        let clock = ManualClock(TestStore.start)
        _ = try TestStore.make(path: roots.database.path, clock: clock, projector: LedgerProjector())
        #expect(HookPlan.contextLine(roots: roots, clock: clock) == nil)
        #expect(HookPlan.contextLine(roots: tempHome(), clock: clock) == nil)
    }

    @Test func aSlowPlanReaderIsAbandonedAfterTwoHundredMilliseconds() throws {
        let roots = tempHome()
        let started = Date()
        let result = HookRunner.run(
            event: "session-start", input: Array(Self.startInput.utf8), spool: roots.spool, now: Self.now,
            plan: { Thread.sleep(forTimeInterval: 2); return "too late" })
        let elapsed = Date().timeIntervalSince(started)
        #expect(result.stdout == nil)
        #expect(elapsed < 0.6)
        #expect(try lines(roots).count == 1)

        let quick = HookRunner.run(
            event: "session-start", input: Array(Self.startInput.utf8), spool: roots.spool, now: Self.now, plan: { "ok" })
        #expect(quick.stdout == "ok")
    }

    // MARK: speed

    @Test func theSpoolPathTakesUnderTenMillisecondsAtTheMedian() throws {
        let roots = tempHome()
        let input = Array(Self.startInput.utf8)
        var samples: [Double] = []
        for _ in 0..<50 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = HookRunner.run(event: "session-start", input: input, spool: roots.spool, now: Self.now, plan: nil)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            #expect(result.warning == nil)
        }
        samples.sort()
        let median = (samples[24] + samples[25]) / 2
        print("hook spool path: median \(median) ms, max \(samples[49]) ms over 50 runs")
        #expect(median < 10)
        #expect(try lines(roots).count == 50)
    }
}
