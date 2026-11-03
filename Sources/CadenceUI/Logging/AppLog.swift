import CadenceCore
import Foundation
import os

/// Where a log line comes from. They are the `category` of the app's `os.Logger`.
public enum LogCategory: String, Sendable, CaseIterable {
    case store, writer, presence, housekeeping, ui
}

/// What was done. A fixed list: a log line names an operation from here and nothing the owner typed.
public enum LogOperation: String, Sendable, CaseIterable {
    case storeOpen = "store.open"
    case dayLoad = "day.load"
    case writeLog = "write.log"
    case writePlanAdd = "write.planAdd"
    case writePlanCommit = "write.planCommit"
    case writeResolve = "write.resolve"
    case writeSeal = "write.seal"
    case writeReopen = "write.reopen"
    case writeDeclare = "write.declare"
    case writeSetStatus = "write.setStatus"
    case writeStandup = "write.standup"
    case writeSpoolDrain = "write.spoolDrain"
    case writeBackup = "write.backup"
    case writeCollectors = "write.collectors"
    case presenceSample = "presence.sample"
    case presenceEvent = "presence.event"
    case presenceSave = "presence.save"
    case presenceDeliver = "presence.deliver"
    case jobSpoolDrain = "job.spoolDrain"
    case jobBackup = "job.backup"
    case jobAgent = "job.agent"
    case jobCollectors = "job.collectors"
}

/// Why something failed, as a fixed word. The same sorting the failure screens use (docs/SPEC.md section 4.6), never
/// the failure's own text, which can quote a title or a path.
public enum LogCode: String, Sendable, CaseIterable {
    case missing
    case busy
    case newerSchema = "newer_schema"
    case denied
    case diskFull = "disk_full"
    case corrupt
    case invalid
    case other
    /// The collector agent is not registered or not allowed to run.
    case agentNotReady = "agent_not_ready"

    public init(_ kind: StoreFailure.Kind) {
        switch kind {
        case .missing: self = .missing
        case .busy: self = .busy
        case .newerSchema: self = .newerSchema
        case .denied: self = .denied
        case .diskFull: self = .diskFull
        case .corrupt: self = .corrupt
        case .invalid: self = .invalid
        case .other: self = .other
        }
    }
}

public enum LogLevel: Sendable, Equatable {
    case debug, info, notice, error
}

/// One log line: an operation, how it went and how long it took. It has no field that can hold free text, so a title, a
/// note, a label or a reason cannot reach the log by any path (docs/SPEC.md section 13).
public struct LogRecord: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case ok
        case failed(LogCode)
        /// A failed try that will be made again.
        case retry(LogCode, attempt: Int)
        case gaveUp(LogCode, attempt: Int)
    }

    /// A success slower than this is kept in the log's store, not only its memory, so a slow day can be read back.
    public static let slowMillis = 250

    public var category: LogCategory
    public var operation: LogOperation
    public var outcome: Outcome
    public var millis: Int

    public init(_ category: LogCategory, _ operation: LogOperation, _ outcome: Outcome, millis: Int) {
        self.category = category
        self.operation = operation
        self.outcome = outcome
        self.millis = max(0, millis)
    }

    /// Failures are errors, a retry or a slow success is a notice, and a presence sample, which comes every half
    /// minute, is debug. A store that does not exist yet is a first run, not an error.
    public var level: LogLevel {
        switch outcome {
        case .failed(.missing): .info
        case .failed, .gaveUp: .error
        case .retry: .notice
        case .ok:
            if millis >= Self.slowMillis { .notice } else if operation == .presenceSample { .debug } else { .info }
        }
    }

    /// `write.log ok 12ms`, `day.load failed code=busy 3ms`, `presence.deliver retry code=busy attempt=1 0ms`.
    public var message: String {
        let how: String
        switch outcome {
        case .ok: how = "ok"
        case .failed(let code): how = "failed code=\(code.rawValue)"
        case .retry(let code, let attempt): how = "retry code=\(code.rawValue) attempt=\(attempt)"
        case .gaveUp(let code, let attempt): how = "gave up code=\(code.rawValue) attempt=\(attempt)"
        }
        return "\(operation.rawValue) \(how) \(millis)ms"
    }
}

/// Where records go: the system log in the app, a capture in tests.
public protocol AppLogSink: Sendable {
    func log(_ record: LogRecord)
}

/// Writes to the system log. Read it with
/// `log show --predicate 'subsystem == "in.ashwingopalsamy.cadence"' --info --last 1h`, the subsystem being the bundle
/// identifier. The message is built only from a `LogRecord`, so it is safe to mark public.
public struct OSLogSink: AppLogSink {
    private let loggers: [LogCategory: Logger]

    public init(subsystem: String) {
        loggers = Dictionary(uniqueKeysWithValues: LogCategory.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })
    }

    public func log(_ record: LogRecord) {
        guard let logger = loggers[record.category] else { return }
        let message = record.message
        switch record.level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }
}

public enum AppLog {
    /// What `cadence doctor` tells the owner to read when the app has no bundle identifier of its own.
    public static let fallbackSubsystem = "in.ashwingopalsamy.cadence"
    /// The bundle identifier, so a build under another `BUNDLE_PREFIX` logs under its own name.
    public static let subsystem = Bundle.main.bundleIdentifier ?? fallbackSubsystem
    public static let system: any AppLogSink = OSLogSink(subsystem: subsystem)
}

/// Milliseconds since it was made, on a clock that does not jump.
struct Stopwatch {
    private let start = ContinuousClock.now

    var millis: Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

extension AppLogSink {
    /// Logs a result's outcome with the time since `watch`. A failure is logged by its kind alone.
    func log<Value>(_ category: LogCategory, _ operation: LogOperation, _ result: Result<Value, StoreFailure>, since watch: Stopwatch) {
        let outcome: LogRecord.Outcome
        switch result {
        case .success: outcome = .ok
        case .failure(let failure): outcome = .failed(LogCode(failure.kind))
        }
        log(LogRecord(category, operation, outcome, millis: watch.millis))
    }
}
