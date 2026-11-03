import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The app's log (docs/SPEC.md section 13): timings and error codes only, never a title, a note or any entry text.
@Suite struct AppLogTests {
    /// Remembers every record the app logs, as the system log would receive it.
    final class CapturingLog: AppLogSink, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [LogRecord] = []
        func log(_ record: LogRecord) { lock.withLock { seen.append(record) } }
        var records: [LogRecord] { lock.withLock { seen } }
        var messages: [String] { records.map(\.message) }
    }

    struct SilentPoster: StoreChangePoster {
        func postStoreChanged() {}
    }

    /// Words that must never reach the log: they appear in the titles, notes, labels, reasons and tickets below.
    static let secrets = ["layoffs", "Quarterly", "ACME-4242", "Bob", "negotiation", "sabbatical", "private reason"]
    static let title = "Quarterly layoffs plan for ACME-4242"

    func home() throws -> DayStoreLoaderTests.Home {
        let home = DayStoreLoaderTests.Home()
        try ConfigStore.save(Config.defaults(timezone: "Asia/Kolkata"), to: home.roots.config)
        return home
    }

    /// A message is an operation, an outcome, and a time. Nothing else fits.
    static func isShapedLikeALogLine(_ message: String) -> Bool {
        message.range(
            of: #"^[a-z]+\.[A-Za-z]+ (ok|failed code=[a-z_]+|retry code=[a-z_]+ attempt=\d+|gave up code=[a-z_]+ attempt=\d+) \d+ms$"#,
            options: .regularExpression) != nil
    }

    static func expectClean(_ messages: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        for message in messages {
            #expect(Self.isShapedLikeALogLine(message), "\(message)", sourceLocation: sourceLocation)
            for secret in secrets {
                #expect(!message.localizedCaseInsensitiveContains(secret), "\(message)", sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: The writer

    @Test func aTitleBearingWriteLogsATimingAndNoTitle() async throws {
        let home = try home()
        defer { home.remove() }
        let sink = CapturingLog()
        let writer = AppWriter(
            location: .found(home.roots), clock: DayStoreLoaderTests.FixedClock(), poster: SilentPoster(), log: sink)

        // Writes that carry text: a title with a ticket, a note, a plan task, a day label and a slip reason.
        let entry = try await writer.perform(.log(LogRequest(text: Self.title, kind: .prMerged, note: "Bob and the negotiation"))).get()
        guard case .entry = entry else { Issue.record("expected an entry"); return }
        let added = try await writer.perform(.planAdd(title: Self.title, day: nil)).get()
        guard case .task(let task) = added else { Issue.record("expected a task"); return }
        _ = try await writer.perform(.resolve(task: task.id, status: .slipped, reason: "private reason")).get()
        _ = try await writer.perform(.declare(day: LocalDate("2026-09-22")!, kind: .leavePlanned, label: "sabbatical")).get()

        // A refusal whose own error text quotes the title: the surface may show it, the log never does.
        let refused = await writer.perform(.resolve(task: Self.title, status: .done, reason: nil))
        guard case .failure(let failure) = refused else { Issue.record("expected a failure"); return }
        #expect(failure.detail.contains("Quarterly") || failure.detail.contains("ACME-4242"))

        let messages = sink.messages
        #expect(messages.count >= 6)
        Self.expectClean(messages)
        #expect(messages.contains { $0.hasPrefix("write.log ok ") })
        #expect(messages.contains { $0.hasPrefix("write.resolve failed code=invalid ") })
        #expect(messages.allSatisfy { $0.hasSuffix("ms") })
        #expect(sink.records.allSatisfy { $0.category == .writer || $0.category == .store })
    }

    @Test func aFailedStoreIsLoggedAsACodeNotAPath() async {
        let sink = CapturingLog()
        let writer = AppWriter(
            location: .failed(StoreFailure(detail: "cannot open /Users/someone/Private/Bob negotiation")),
            clock: DayStoreLoaderTests.FixedClock(), poster: SilentPoster(), log: sink)
        _ = await writer.perform(.planAdd(title: Self.title, day: nil))
        _ = await writer.recordPresence(.lock, at: DayStoreLoaderTests.FixedClock().now())
        _ = await writer.drainSpool()
        _ = await writer.runBackup()
        _ = await writer.collectorSources()

        Self.expectClean(sink.messages)
        #expect(sink.messages.allSatisfy { !$0.contains("/Users") })
        #expect(sink.messages.contains { $0.hasPrefix("write.planAdd failed code=other ") })
        #expect(sink.messages.contains { $0.hasPrefix("presence.event failed code=other ") })
        #expect(sink.messages.contains { $0.hasPrefix("write.spoolDrain failed code=other ") })
        #expect(sink.messages.contains { $0.hasPrefix("write.backup failed code=other ") })
        #expect(sink.messages.contains { $0.hasPrefix("write.collectors failed code=other ") })
    }

    @Test func presenceSamplesAreLoggedAtDebugAndOtherEventsAtInfo() async throws {
        let home = try home()
        defer { home.remove() }
        let sink = CapturingLog()
        let clock = ManualClock(PresencePipelineTests.at(9, 0))
        let writer = AppWriter(location: .found(home.roots), clock: clock, poster: SilentPoster(), log: sink)
        _ = try await writer.recordPresence(.sample(idleSeconds: 0, unlocked: true), at: PresencePipelineTests.at(9, 0)).get()
        clock.set(PresencePipelineTests.at(9, 2))
        _ = try await writer.recordPresence(.lock, at: PresencePipelineTests.at(9, 2)).get()

        let presence = sink.records.filter { $0.category == .presence }
        #expect(presence.count == 2)
        #expect(presence.first?.message.hasPrefix("presence.sample ok ") == true)
        #expect(presence.first?.level == .debug)
        #expect(presence.last?.message.hasPrefix("presence.event ok ") == true)
        #expect(presence.last?.level == .info)
        Self.expectClean(sink.messages)
    }

    // MARK: The loader

    @Test func theLoaderLogsItsTimingAndOnlyACodeOnFailure() throws {
        let home = try home()
        defer { home.remove() }
        _ = try home.journal().log(LogRequest(text: Self.title, kind: .prMerged), actor: .cli, origin: .selfReported)
        let sink = CapturingLog()

        let loaded = DayStoreLoader(location: .found(home.roots), clock: DayStoreLoaderTests.FixedClock(), log: sink).load()
        guard case .loaded = loaded else { Issue.record("expected a day"); return }
        let failed = DayStoreLoader(
            location: .failed(StoreFailure(detail: "no \(Self.title)")), clock: DayStoreLoaderTests.FixedClock(), log: sink
        ).load()
        guard case .failed = failed else { Issue.record("expected a failure"); return }

        #expect(sink.messages.count == 2)
        #expect(sink.messages[0].hasPrefix("day.load ok "))
        #expect(sink.messages[1].hasPrefix("day.load failed code=other "))
        #expect(sink.records.allSatisfy { $0.category == .store })
        Self.expectClean(sink.messages)
    }

    // MARK: Presence and the jobs

    @Test func presenceRetriesLogTheAttemptAndTheCodeNotTheEvent() async {
        let clock = ManualClock(PresencePipelineTests.at(9, 0))
        let recorder = PresencePipelineTests.ScriptedRecorder(failing: [.busy, .diskFull, .busy, .busy, .busy])
        let sink = CapturingLog()
        let feed = PresencePipeline(
            recorder: recorder, clock: clock, retry: PresenceRetry(maxAttempts: 3, delays: [1]), sleep: { _ in }, log: sink)
        let source = PresencePipelineTests.FakeSource()
        feed.start(source: source)
        source.emit(.lock)
        await feed.drain()

        #expect(
            sink.messages.map { $0.replacingOccurrences(of: #" \d+ms$"#, with: " Nms", options: .regularExpression) } == [
                "presence.deliver retry code=busy attempt=1 Nms",
                "presence.deliver retry code=disk_full attempt=2 Nms",
                "presence.deliver gave up code=busy attempt=3 Nms",
            ])
        Self.expectClean(sink.messages)
        #expect(sink.records.allSatisfy { $0.category == .presence })
    }

    @Test func jobsLogTheirOutcomeAsACodeEvenWhenTheirOwnMessageHasText() async {
        let work = HousekeepingTests.FakeWork()
        work.drain = { .failure(StoreFailure(kind: .other, detail: "cannot read the spool for \(Self.title)")) }
        work.backup = { .success(BackupOutcome(created: true, day: "2026-10-29", events: 4, pruned: 0)) }
        work.sources = { .failure(StoreFailure(kind: .busy, detail: "the store is busy")) }
        let sink = CapturingLog()
        let hk = Housekeeping(
            work: work, agent: HousekeepingTests.FakeAgent(.requiresApproval), signal: HousekeepingTests.FakeSignal(),
            clock: ManualClock(HousekeepingTests.at(9, 0)), log: sink)
        for job in HousekeepingJob.allCases { await hk.run(job) }

        let plain = sink.messages.map { $0.replacingOccurrences(of: #" \d+ms$"#, with: " Nms", options: .regularExpression) }
        #expect(
            plain == [
                "job.spoolDrain failed code=other Nms",
                "job.backup ok Nms",
                "job.agent failed code=agent_not_ready Nms",
                "job.collectors failed code=busy Nms",
            ])
        // The health the app shows keeps the words; the log does not.
        #expect(hk.status.jobs[.spoolDrain]?.message?.contains("Quarterly") == true)
        Self.expectClean(sink.messages)
        #expect(sink.records.allSatisfy { $0.category == .housekeeping })
    }

    // MARK: The record

    @Test func everyOperationAndCodeIsAFixedWord() {
        for operation in LogOperation.allCases {
            #expect(operation.rawValue.range(of: #"^[a-z]+\.[A-Za-z]+$"#, options: .regularExpression) != nil, "\(operation)")
        }
        for code in LogCode.allCases {
            #expect(code.rawValue.range(of: #"^[a-z_]+$"#, options: .regularExpression) != nil, "\(code)")
        }
        #expect(Set(LogCategory.allCases.map(\.rawValue)) == ["store", "writer", "presence", "housekeeping", "ui"])
    }

    @Test func aFailureIsAnErrorAndASlowSuccessIsANotice() {
        func level(_ outcome: LogRecord.Outcome, _ millis: Int, _ operation: LogOperation = .writeLog) -> LogLevel {
            LogRecord(.writer, operation, outcome, millis: millis).level
        }
        #expect(level(.ok, 3) == .info)
        #expect(level(.ok, LogRecord.slowMillis) == .notice)
        #expect(level(.failed(.busy), 1) == .error)
        #expect(level(.failed(.missing), 1) == .info)
        #expect(level(.gaveUp(.busy, attempt: 4), 1) == .error)
        #expect(level(.retry(.busy, attempt: 1), 1) == .notice)
        #expect(level(.ok, 1, .presenceSample) == .debug)
    }

    @Test func codesComeFromTheFailureKindsTheSurfacesAlreadyUse() {
        #expect(LogCode(.busy) == .busy)
        #expect(LogCode(.missing) == .missing)
        #expect(LogCode(.newerSchema) == .newerSchema)
        #expect(LogCode(.denied) == .denied)
        #expect(LogCode(.diskFull) == .diskFull)
        #expect(LogCode(.corrupt) == .corrupt)
        #expect(LogCode(.invalid) == .invalid)
        #expect(LogCode(.other) == .other)
    }

    @Test func theSystemSinkNamesItsSubsystemFromTheBundleWithAFixedFallback() {
        // `cadence doctor` tells the owner to read this subsystem, so the fallback is pinned.
        #expect(AppLog.fallbackSubsystem == "in.ashwingopalsamy.cadence")
        #expect(AppLog.subsystem == (Bundle.main.bundleIdentifier ?? AppLog.fallbackSubsystem))
        // One record per level reaches os.Logger without trouble.
        let sink = OSLogSink(subsystem: "in.ashwingopalsamy.cadence.tests")
        sink.log(LogRecord(.writer, .writeLog, .ok, millis: 1))
        sink.log(LogRecord(.writer, .writeLog, .ok, millis: LogRecord.slowMillis))
        sink.log(LogRecord(.presence, .presenceSample, .ok, millis: 0))
        sink.log(LogRecord(.writer, .writeLog, .failed(.busy), millis: 2))
    }
}
