import Foundation

/// The hook events Claude Code can send (docs/SPEC.md section 9.3). The raw value is the command argument.
public enum HookEventName: String, Sendable, CaseIterable {
    case sessionStart = "session-start"
    case sessionEnd = "session-end"
    case stop
    case taskCompleted = "task-completed"
}

/// What `cadence hook <event>` does with the hook JSON (docs/SPEC.md section 9.3).
///
/// This file must never touch the store: the hook runs inside Claude Code's budget and a locked or broken
/// database must not slow it down. Only the allowlisted fields below are kept. Prompts, tool inputs and
/// outputs, transcript paths and file paths never reach the spool; the working folder is reduced to its
/// last component (the project alias).
public enum HookSpool {
    public static let version: Int64 = 1
    static let maxField = 128
    static let maxAlias = 64

    /// The one spool line for a hook call, canonical JSON plus a newline. Nil when the input is not a JSON
    /// object with a usable `session_id`.
    public static func line(event: HookEventName, input: [UInt8], now: Date) -> [UInt8]? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(input))) as? [String: Any],
            let sessionId = object["session_id"] as? String, isSafeSessionId(sessionId)
        else { return nil }
        var fields: [String: JSONValue] = [
            "v": .int(version), "event": .string(event.rawValue), "at": .string(Timestamp.utc(now)),
            "session_id": .string(sessionId),
        ]
        func text(_ key: String) -> String? { (object[key] as? String).flatMap { clean($0, limit: maxField) } }
        switch event {
        case .sessionStart:
            if let value = text("source") { fields["source"] = .string(value) }
            if let value = text("model") { fields["model"] = .string(value) }
        case .sessionEnd:
            if let value = text("reason") { fields["reason"] = .string(value) }
        case .stop:
            break
        case .taskCompleted:
            // Field names are unconfirmed (docs/SPEC.md section 9.3): keep only an id if one arrives.
            if let value = text("task_id") { fields["task_id"] = .string(value) }
        }
        if let alias = (object["cwd"] as? String).flatMap({ projectAlias(cwd: $0) }) { fields["project"] = .string(alias) }
        guard let bytes = try? CanonicalJSON.bytes(.object(fields)) else { return nil }
        return bytes + [0x0A]
    }

    /// The folder name of a working directory, or nil for the root or an empty path.
    public static func projectAlias(cwd: String) -> String? {
        let last = cwd.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        return clean(last, limit: maxAlias)
    }

    static func isSafeSessionId(_ text: String) -> Bool {
        guard (1...maxField).contains(text.utf8.count) else { return false }
        return text.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E || $0 == 0x3A
        }
    }

    /// Drops control characters, trims, caps the length. Nil when nothing is left.
    static func clean(_ text: String, limit: Int) -> String? {
        let scalars = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        let trimmed = String(String.UnicodeScalarView(scalars.prefix(limit)))
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `spool/hooks-YYYY-MM-DD.ndjson`, the date in UTC.
    public static func fileURL(in spool: URL, now: Date) -> URL {
        spool.appendingPathComponent("hooks-\(Timestamp.utc(now).prefix(10)).ndjson")
    }

    /// Appends `line` with a single write(2) to a file opened O_APPEND|O_CREAT, mode 0600. The spool folder
    /// is created with mode 0700 if it is missing.
    public static func append(_ line: [UInt8], spool: URL, now: Date) throws(CadenceError) {
        makeFolder(spool)
        let fd = open(fileURL(in: spool, now: now).path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw .io("cannot open the spool") }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == line.count else { throw .io("cannot write the spool") }
    }

    private static func makeFolder(_ folder: URL) {
        if mkdir(folder.path, 0o700) == 0 || errno == EEXIST { return }
        if errno == ENOENT {
            _ = mkdir(folder.deletingLastPathComponent().path, 0o700)
            _ = mkdir(folder.path, 0o700)
        }
    }
}

/// The outcome of one hook call. `stdout` is the text for Claude Code; `warning` is one line for stderr.
public struct HookResult: Sendable, Equatable {
    public var stdout: String?
    public var warning: String?
}

public enum HookRunner {
    /// The hard cap on reading the plan at SessionStart.
    public static let planLimit: TimeInterval = 0.2

    /// Records the hook call, then at SessionStart asks `plan` for the context line. `plan` runs on its own
    /// thread and is abandoned after `planLimit`; nothing is printed then. Never throws.
    public static func run(
        event name: String, input: [UInt8], spool: URL, now: Date, plan: (@Sendable () -> String?)?
    ) -> HookResult {
        guard let event = HookEventName(rawValue: name) else {
            return HookResult(stdout: nil, warning: "unknown hook event '\(name.prefix(40))'")
        }
        var result = HookResult()
        if let line = HookSpool.line(event: event, input: input, now: now) {
            do {
                try HookSpool.append(line, spool: spool, now: now)
            } catch {
                result.warning = error.message
            }
        } else {
            result.warning = "ignored a hook call without a usable session id"
        }
        if event == .sessionStart, let plan {
            result.stdout = withDeadline(planLimit, plan)
        }
        return result
    }

    static func withDeadline(_ seconds: TimeInterval, _ body: @escaping @Sendable () -> String?) -> String? {
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.start()
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.value
    }
}
