import Foundation

/// A strict reader for one payload object (docs/SPEC.md section 7.3). The key set is fixed:
/// a missing key and an unknown key are both validation errors, and optional fields are present as null.
struct PayloadReader {
    let owner: String
    let fields: [String: JSONValue]

    init(_ json: JSONValue, owner: String, keys: [String]) throws(CadenceError) {
        guard case .object(let object) = json else { throw .validation("\(owner): expected an object") }
        for key in keys where object[key] == nil { throw .validation("\(owner).\(key): is required") }
        let allowed = Set(keys)
        for key in object.keys.sorted() where !allowed.contains(key) {
            throw .validation("\(owner).\(key): unknown key")
        }
        self.owner = owner
        self.fields = object
    }

    func fail(_ key: String, _ what: String) -> CadenceError { .validation("\(owner).\(key): \(what)") }

    func raw(_ key: String) -> JSONValue { fields[key] ?? .null }

    func string(_ key: String) throws(CadenceError) -> String {
        guard let s = raw(key).stringValue else { throw fail(key, "must be a string") }
        return s
    }

    func optionalString(_ key: String) throws(CadenceError) -> String? {
        if raw(key).isNull { return nil }
        return try string(key)
    }

    func int(_ key: String) throws(CadenceError) -> Int64 {
        guard let i = raw(key).intValue else { throw fail(key, "must be an integer") }
        guard i >= 0 else { throw fail(key, "must not be negative") }
        return i
    }

    func optionalInt(_ key: String) throws(CadenceError) -> Int64? {
        if raw(key).isNull { return nil }
        return try int(key)
    }

    func bool(_ key: String) throws(CadenceError) -> Bool {
        guard let b = raw(key).boolValue else { throw fail(key, "must be a boolean") }
        return b
    }

    func optionalBool(_ key: String) throws(CadenceError) -> Bool? {
        if raw(key).isNull { return nil }
        return try bool(key)
    }

    func day(_ key: String) throws(CadenceError) -> String {
        let s = try string(key)
        guard LocalDate(s) != nil else { throw fail(key, "must be a date as YYYY-MM-DD") }
        return s
    }

    /// An IANA zone name such as "Asia/Kolkata" that this system knows.
    func zone(_ key: String) throws(CadenceError) -> String {
        let s = try string(key)
        guard EventPayload.isZone(s) else { throw fail(key, "must be a known time zone name") }
        return s
    }

    func time(_ key: String) throws(CadenceError) -> String {
        let s = try string(key)
        guard Timestamp.parse(s) != nil else { throw fail(key, "must be an RFC 3339 time") }
        return s
    }

    func optionalTime(_ key: String) throws(CadenceError) -> String? {
        if raw(key).isNull { return nil }
        return try time(key)
    }

    func enumValue<E: RawRepresentable>(_ key: String, as _: E.Type = E.self) throws(CadenceError) -> E
    where E.RawValue == String {
        let s = try string(key)
        guard let e = E(rawValue: s) else { throw fail(key, "unknown value '\(s)'") }
        return e
    }

    func strings(_ key: String) throws(CadenceError) -> [String] {
        guard let items = raw(key).arrayValue else { throw fail(key, "must be an array of strings") }
        var out: [String] = []
        for item in items {
            guard let s = item.stringValue else { throw fail(key, "must be an array of strings") }
            out.append(s)
        }
        return out
    }

    func object(_ key: String) throws(CadenceError) -> [String: JSONValue] {
        guard let o = raw(key).objectValue else { throw fail(key, "must be an object") }
        return o
    }

    func counts(_ key: String) throws(CadenceError) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for (k, v) in try object(key) {
            guard let i = v.intValue else { throw fail(key, "'\(k)' must be an integer") }
            guard i >= 0 else { throw fail(key, "'\(k)' must not be negative") }
            out[k] = i
        }
        return out
    }
}

/// One field's change: `[old, new]`.
public struct Change: Sendable, Equatable {
    public var old: JSONValue
    public var new: JSONValue

    public init(old: JSONValue, new: JSONValue) {
        self.old = old
        self.new = new
    }
}

/// The `changes` object of `plan.updated` and `entry.updated`: field to `[old, new]`.
public struct Changes: Sendable, Equatable, JSONRepresentable {
    public static let planFields: Set<String> = ["title", "ticket", "estimate_min", "position"]
    public static let entryFields: Set<String> = [
        "title", "kind", "family", "occurred_at", "duration_s", "quantity", "ticket", "links", "tags",
        "attrs", "day", "export", "backfilled", "after_seal",
    ]

    public var fields: [String: Change]

    public init(fields: [String: Change]) { self.fields = fields }

    public var json: JSONValue {
        var changes: [String: JSONValue] = [:]
        for (key, change) in fields { changes[key] = .array([change.old, change.new]) }
        return ["changes": .object(changes)]
    }

    /// Accepts any field name. Use `init(json:allowed:owner:)` to restrict to an event type's fields.
    public init(json: JSONValue) throws(CadenceError) {
        try self.init(json: json, allowed: nil, owner: "changes")
    }

    public init(json: JSONValue, allowed: Set<String>?, owner: String) throws(CadenceError) {
        let r = try PayloadReader(json, owner: owner, keys: ["changes"])
        let changes = try r.object("changes")
        if changes.isEmpty { throw r.fail("changes", "must name at least one field") }
        var out: [String: Change] = [:]
        for key in changes.keys.sorted() {
            if let allowed, !allowed.contains(key) {
                throw .validation("\(owner).changes.\(key): field cannot be changed")
            }
            guard let pair = changes[key]?.arrayValue, pair.count == 2 else {
                throw .validation("\(owner).changes.\(key): must be [old, new]")
            }
            out[key] = Change(old: pair[0], new: pair[1])
        }
        self.fields = out
    }
}

public struct Genesis: Sendable, Equatable, JSONRepresentable {
    public var created: String
    public var appVersion: String
    public var profile: [String: JSONValue]

    public init(created: String, appVersion: String, profile: [String: JSONValue]) {
        self.created = created
        self.appVersion = appVersion
        self.profile = profile
    }

    public var json: JSONValue {
        ["created": .string(created), "app_version": .string(appVersion), "profile": .object(profile)]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(json, owner: "ledger.genesis", keys: ["created", "app_version", "profile"])
        created = try r.time("created")
        appVersion = try r.string("app_version")
        profile = try r.object("profile")
    }
}

/// `day.started` and `day.ended`: a day boundary marked at an instant.
public struct DayMark: Sendable, Equatable, JSONRepresentable {
    public var day: String
    public var tz: String
    public var at: String
    public var source: PresenceSource

    public init(day: String, tz: String, at: String, source: PresenceSource) {
        self.day = day
        self.tz = tz
        self.at = at
        self.source = source
    }

    public var json: JSONValue {
        ["day": .string(day), "tz": .string(tz), "at": .string(at), "source": .string(source.rawValue)]
    }

    public init(json: JSONValue) throws(CadenceError) {
        try self.init(json, owner: "day.started")
    }

    init(_ json: JSONValue, owner: String) throws(CadenceError) {
        let r = try PayloadReader(json, owner: owner, keys: ["day", "tz", "at", "source"])
        day = try r.day("day")
        tz = try r.zone("tz")
        at = try r.time("at")
        source = try r.enumValue("source")
        guard EventPayload.isWithinWorkday(at, day: day, tz: tz) else { throw r.fail("at", "is outside the day") }
    }
}

public struct PresenceSpanPayload: Sendable, Equatable, JSONRepresentable {
    public var day: String
    public var tz: String
    public var start: String
    public var end: String
    public var source: PresenceSource

    public init(day: String, tz: String, start: String, end: String, source: PresenceSource) {
        self.day = day
        self.tz = tz
        self.start = start
        self.end = end
        self.source = source
    }

    public var json: JSONValue {
        [
            "day": .string(day), "tz": .string(tz), "start": .string(start), "end": .string(end),
            "source": .string(source.rawValue),
        ]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(
            json, owner: "presence.span", keys: ["day", "tz", "start", "end", "source"])
        day = try r.day("day")
        tz = try r.zone("tz")
        start = try r.time("start")
        end = try r.time("end")
        source = try r.enumValue("source")
        guard let a = Timestamp.parse(start), let b = Timestamp.parse(end), a <= b else {
            throw r.fail("end", "must not be before start")
        }
        guard EventPayload.isWithinWorkday(start, day: day, tz: tz), EventPayload.isWithinWorkday(end, day: day, tz: tz)
        else { throw r.fail("start", "the span is outside the day") }
    }
}

public struct DayDeclared: Sendable, Equatable, JSONRepresentable {
    public var day: String
    public var tz: String
    public var kind: DayKind
    public var label: String?

    public init(day: String, tz: String, kind: DayKind, label: String? = nil) {
        self.day = day
        self.tz = tz
        self.kind = kind
        self.label = label
    }

    public var json: JSONValue {
        ["day": .string(day), "tz": .string(tz), "kind": .string(kind.rawValue), "label": label.jsonValue]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(json, owner: "day.declared", keys: ["day", "tz", "kind", "label"])
        day = try r.day("day")
        tz = try r.zone("tz")
        kind = try r.enumValue("kind")
        label = try r.optionalString("label")
    }
}

public struct DayNoted: Sendable, Equatable, JSONRepresentable {
    public var day: String
    public var tz: String
    public var focus: String?
    public var note: String?
    /// nil means unchanged.
    public var onCall: Bool?

    public init(day: String, tz: String, focus: String? = nil, note: String? = nil, onCall: Bool? = nil) {
        self.day = day
        self.tz = tz
        self.focus = focus
        self.note = note
        self.onCall = onCall
    }

    public var json: JSONValue {
        [
            "day": .string(day), "tz": .string(tz), "focus": focus.jsonValue, "note": note.jsonValue,
            "on_call": onCall.map { .bool($0) } ?? .null,
        ]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(json, owner: "day.noted", keys: ["day", "tz", "focus", "note", "on_call"])
        day = try r.day("day")
        tz = try r.zone("tz")
        focus = try r.optionalString("focus")
        note = try r.optionalString("note")
        onCall = try r.optionalBool("on_call")
    }
}

public struct PlanResolved: Sendable, Equatable, JSONRepresentable {
    public var status: TaskStatus
    public var reason: String?
    public var reasonNote: String?
    public var links: [String]

    public init(status: TaskStatus, reason: String? = nil, reasonNote: String? = nil, links: [String] = []) {
        self.status = status
        self.reason = reason
        self.reasonNote = reasonNote
        self.links = links
    }

    public var json: JSONValue {
        [
            "status": .string(status.rawValue), "reason": reason.jsonValue, "reason_note": reasonNote.jsonValue,
            "links": .array(links.map { .string($0) }),
        ]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(
            json, owner: "plan.resolved", keys: ["status", "reason", "reason_note", "links"])
        status = try r.enumValue("status")
        reason = try r.optionalString("reason")
        reasonNote = try r.optionalString("reason_note")
        links = try r.strings("links")
    }
}

public struct PlanCommitted: Sendable, Equatable, JSONRepresentable {
    public var day: String
    public var tz: String
    public var focus: String?
    public var tasks: [String]

    public init(day: String, tz: String, focus: String? = nil, tasks: [String]) {
        self.day = day
        self.tz = tz
        self.focus = focus
        self.tasks = tasks
    }

    public var json: JSONValue {
        [
            "day": .string(day), "tz": .string(tz), "focus": focus.jsonValue,
            "tasks": .array(tasks.map { .string($0) }),
        ]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(json, owner: "plan.committed", keys: ["day", "tz", "focus", "tasks"])
        day = try r.day("day")
        tz = try r.zone("tz")
        focus = try r.optionalString("focus")
        tasks = try r.strings("tasks")
    }
}

public struct EntryStatusChange: Sendable, Equatable, JSONRepresentable {
    public var from: EntryStatus
    public var to: EntryStatus
    public var note: String?

    public init(from: EntryStatus, to: EntryStatus, note: String? = nil) {
        self.from = from
        self.to = to
        self.note = note
    }

    public var json: JSONValue {
        ["from": .string(from.rawValue), "to": .string(to.rawValue), "note": note.jsonValue]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(json, owner: "entry.status", keys: ["from", "to", "note"])
        from = try r.enumValue("from")
        to = try r.enumValue("to")
        note = try r.optionalString("note")
    }
}

/// The plan tally recorded when a day is sealed.
public struct PlanCounts: Sendable, Equatable, JSONRepresentable {
    public var done: Int64
    public var slipped: Int64
    public var dropped: Int64
    public var moved: Int64
    public var open: Int64

    public init(done: Int64, slipped: Int64, dropped: Int64, moved: Int64, open: Int64) {
        self.done = done
        self.slipped = slipped
        self.dropped = dropped
        self.moved = moved
        self.open = open
    }

    public var json: JSONValue {
        [
            "done": .int(done), "slipped": .int(slipped), "dropped": .int(dropped), "moved": .int(moved),
            "open": .int(open),
        ]
    }

    public init(json: JSONValue) throws(CadenceError) {
        try self.init(json, owner: "day.sealed.plan")
    }

    init(_ json: JSONValue, owner: String) throws(CadenceError) {
        let r = try PayloadReader(json, owner: owner, keys: ["done", "slipped", "dropped", "moved", "open"])
        done = try r.int("done")
        slipped = try r.int("slipped")
        dropped = try r.int("dropped")
        moved = try r.int("moved")
        open = try r.int("open")
    }
}

public struct DaySealed: Sendable, Equatable, JSONRepresentable {
    public var day: String
    public var tz: String
    public var counts: [String: Int64]
    public var plan: PlanCounts
    /// Hash of the event before the seal.
    public var head: String

    public init(day: String, tz: String, counts: [String: Int64], plan: PlanCounts, head: String) {
        self.day = day
        self.tz = tz
        self.counts = counts
        self.plan = plan
        self.head = head
    }

    public var json: JSONValue {
        var c: [String: JSONValue] = [:]
        for (k, v) in counts { c[k] = .int(v) }
        return ["day": .string(day), "tz": .string(tz), "counts": .object(c), "plan": plan.json, "head": .string(head)]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(json, owner: "day.sealed", keys: ["day", "tz", "counts", "plan", "head"])
        day = try r.day("day")
        tz = try r.zone("tz")
        counts = try r.counts("counts")
        plan = try PlanCounts(r.raw("plan"), owner: "day.sealed.plan")
        head = try r.string("head")
        let hex = head.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
        guard head.utf8.count == 64, hex else { throw r.fail("head", "must be 64 lowercase hex characters") }
    }
}

/// A sealed day opened again (docs/SPEC.md section 3). The payload names the day and nothing else: no reason, no free
/// text and no zone, so the owner's words never reach the ledger through it. The time is the event's own `at`.
public struct DayReopened: Sendable, Equatable, JSONRepresentable {
    public var day: String

    public init(day: String) {
        self.day = day
    }

    public var json: JSONValue { ["day": .string(day)] }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(json, owner: "day.reopened", keys: ["day"])
        day = try r.day("day")
    }
}

public struct WitnessCheckpoint: Sendable, Equatable, JSONRepresentable {
    public var day: String
    public var purpose: String

    public init(day: String, purpose: String) {
        self.day = day
        self.purpose = purpose
    }

    public var json: JSONValue { ["day": .string(day), "purpose": .string(purpose)] }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(json, owner: "witness.checkpoint", keys: ["day", "purpose"])
        day = try r.day("day")
        purpose = try r.string("purpose")
    }
}

public struct GenAISession: Sendable, Equatable, JSONRepresentable {
    public var sessionId: String
    public var tool: String
    public var day: String
    public var startedAt: String
    public var endedAt: String?
    public var endReason: String?
    public var projectAlias: String?
    public var models: [String]
    public var turns: Int64?

    public init(
        sessionId: String, tool: String, day: String, startedAt: String, endedAt: String? = nil,
        endReason: String? = nil, projectAlias: String? = nil, models: [String] = [], turns: Int64? = nil
    ) {
        self.sessionId = sessionId
        self.tool = tool
        self.day = day
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.projectAlias = projectAlias
        self.models = models
        self.turns = turns
    }

    public var json: JSONValue {
        [
            "session_id": .string(sessionId), "tool": .string(tool), "day": .string(day),
            "started_at": .string(startedAt), "ended_at": endedAt.jsonValue, "end_reason": endReason.jsonValue,
            "project_alias": projectAlias.jsonValue, "models": .array(models.map { .string($0) }),
            "turns": turns.jsonValue,
        ]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(
            json, owner: "genai.session",
            keys: [
                "session_id", "tool", "day", "started_at", "ended_at", "end_reason", "project_alias",
                "models", "turns",
            ])
        sessionId = try r.string("session_id")
        tool = try r.string("tool")
        day = try r.day("day")
        startedAt = try r.time("started_at")
        endedAt = try r.optionalTime("ended_at")
        endReason = try r.optionalString("end_reason")
        projectAlias = try r.optionalString("project_alias")
        models = try r.strings("models")
        turns = try r.optionalInt("turns")
    }
}

public struct TokenCounts: Sendable, Equatable, JSONRepresentable {
    public var input: Int64?
    public var output: Int64?
    public var cacheRead: Int64?
    public var cacheWrite: Int64?

    public init(input: Int64? = nil, output: Int64? = nil, cacheRead: Int64? = nil, cacheWrite: Int64? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var json: JSONValue {
        [
            "in": input.jsonValue, "out": output.jsonValue, "cache_read": cacheRead.jsonValue,
            "cache_write": cacheWrite.jsonValue,
        ]
    }

    public init(json: JSONValue) throws(CadenceError) {
        try self.init(json, owner: "genai.usage.tokens")
    }

    init(_ json: JSONValue, owner: String) throws(CadenceError) {
        let r = try PayloadReader(json, owner: owner, keys: ["in", "out", "cache_read", "cache_write"])
        input = try r.optionalInt("in")
        output = try r.optionalInt("out")
        cacheRead = try r.optionalInt("cache_read")
        cacheWrite = try r.optionalInt("cache_write")
    }
}

public struct GenAIUsage: Sendable, Equatable, JSONRepresentable {
    public var day: String
    public var tool: String
    /// "*" when unknown.
    public var model: String
    public var source: String
    /// Nil when the source does not count sessions: unknown is not zero.
    public var sessions: Int64?
    public var requests: Int64?
    public var tokens: TokenCounts
    public var costMicros: Int64?
    public var estimated: Bool

    public init(
        day: String, tool: String, model: String, source: String, sessions: Int64?, requests: Int64? = nil,
        tokens: TokenCounts = TokenCounts(), costMicros: Int64? = nil, estimated: Bool = false
    ) {
        self.day = day
        self.tool = tool
        self.model = model
        self.source = source
        self.sessions = sessions
        self.requests = requests
        self.tokens = tokens
        self.costMicros = costMicros
        self.estimated = estimated
    }

    public var json: JSONValue {
        [
            "day": .string(day), "tool": .string(tool), "model": .string(model), "source": .string(source),
            "sessions": sessions.jsonValue, "requests": requests.jsonValue, "tokens": tokens.json,
            "cost_micros": costMicros.jsonValue, "estimated": .bool(estimated),
        ]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(
            json, owner: "genai.usage",
            keys: [
                "day", "tool", "model", "source", "sessions", "requests", "tokens", "cost_micros",
                "estimated",
            ])
        day = try r.day("day")
        tool = try r.string("tool")
        model = try r.string("model")
        source = try r.string("source")
        sessions = try r.optionalInt("sessions")
        requests = try r.optionalInt("requests")
        tokens = try TokenCounts(r.raw("tokens"), owner: "genai.usage.tokens")
        costMicros = try r.optionalInt("cost_micros")
        estimated = try r.bool("estimated")
    }
}

public struct IngestRun: Sendable, Equatable, JSONRepresentable {
    public var collector: String
    public var since: String
    public var until: String
    public var counts: [String: Int64]
    public var errors: [String]
    /// "ok" or "error".
    public var status: String

    public init(
        collector: String, since: String, until: String, counts: [String: Int64], errors: [String],
        status: String
    ) {
        self.collector = collector
        self.since = since
        self.until = until
        self.counts = counts
        self.errors = errors
        self.status = status
    }

    public var json: JSONValue {
        var c: [String: JSONValue] = [:]
        for (k, v) in counts { c[k] = .int(v) }
        return [
            "collector": .string(collector),
            "window": ["since": .string(since), "until": .string(until)],
            "counts": .object(c), "errors": .array(errors.map { .string($0) }), "status": .string(status),
        ]
    }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(
            json, owner: "ingest.run", keys: ["collector", "window", "counts", "errors", "status"])
        collector = try r.string("collector")
        let w = try PayloadReader(r.raw("window"), owner: "ingest.run.window", keys: ["since", "until"])
        since = try IngestRun.windowEdge(w, "since")
        until = try IngestRun.windowEdge(w, "until")
        counts = try r.counts("counts")
        errors = try r.strings("errors")
        status = try r.string("status")
        guard status == "ok" || status == "error" else { throw r.fail("status", "must be 'ok' or 'error'") }
    }

    /// A window edge is a day or an RFC 3339 time.
    private static func windowEdge(_ w: PayloadReader, _ key: String) throws(CadenceError) -> String {
        let s = try w.string(key)
        guard LocalDate(s) != nil || Timestamp.parse(s) != nil else {
            throw w.fail(key, "must be a day or an RFC 3339 time")
        }
        return s
    }
}

public struct ConfigClassifier: Sendable, Equatable, JSONRepresentable {
    public var patterns: [String]

    public init(patterns: [String]) { self.patterns = patterns }

    public var json: JSONValue { ["patterns": .array(patterns.map { .string($0) })] }

    public init(json: JSONValue) throws(CadenceError) {
        let r = try PayloadReader(json, owner: "config.classifier", keys: ["patterns"])
        patterns = try r.strings("patterns")
    }
}

/// Every ledger event type with a typed payload (docs/SPEC.md section 7.3). Decoding is strict:
/// the key set is fixed and every value is checked, so what the ledger hashes has one shape.
public enum EventPayload: Sendable, Equatable {
    case genesis(Genesis)
    case dayStarted(DayMark)
    case dayEnded(DayMark)
    case presenceSpan(PresenceSpanPayload)
    case dayDeclared(DayDeclared)
    case dayNoted(DayNoted)
    case planAdded(PlanTask)
    case planUpdated(Changes)
    case planResolved(PlanResolved)
    case planCommitted(PlanCommitted)
    case entryCreated(Entry)
    case entryUpdated(Changes)
    case entryStatus(EntryStatusChange)
    case daySealed(DaySealed)
    case dayReopened(DayReopened)
    case witness(WitnessCheckpoint)
    case genaiSession(GenAISession)
    case genaiUsage(GenAIUsage)
    case ingestRun(IngestRun)
    case configClassifier(ConfigClassifier)

    public static let allTypes: [String] = [
        "ledger.genesis", "day.started", "day.ended", "presence.span", "day.declared", "day.noted",
        "plan.added", "plan.updated", "plan.resolved", "plan.committed", "entry.created", "entry.updated",
        "entry.status", "day.sealed", "day.reopened", "witness.checkpoint", "genai.session", "genai.usage",
        "ingest.run", "config.classifier",
    ]

    public var type: String {
        switch self {
        case .genesis: "ledger.genesis"
        case .dayStarted: "day.started"
        case .dayEnded: "day.ended"
        case .presenceSpan: "presence.span"
        case .dayDeclared: "day.declared"
        case .dayNoted: "day.noted"
        case .planAdded: "plan.added"
        case .planUpdated: "plan.updated"
        case .planResolved: "plan.resolved"
        case .planCommitted: "plan.committed"
        case .entryCreated: "entry.created"
        case .entryUpdated: "entry.updated"
        case .entryStatus: "entry.status"
        case .daySealed: "day.sealed"
        case .dayReopened: "day.reopened"
        case .witness: "witness.checkpoint"
        case .genaiSession: "genai.session"
        case .genaiUsage: "genai.usage"
        case .ingestRun: "ingest.run"
        case .configClassifier: "config.classifier"
        }
    }

    public var data: JSONValue {
        switch self {
        case .genesis(let p): p.json
        case .dayStarted(let p), .dayEnded(let p): p.json
        case .presenceSpan(let p): p.json
        case .dayDeclared(let p): p.json
        case .dayNoted(let p): p.json
        case .planAdded(let p): p.json
        case .planUpdated(let p), .entryUpdated(let p): p.json
        case .planResolved(let p): p.json
        case .planCommitted(let p): p.json
        case .entryCreated(let p): p.json
        case .entryStatus(let p): p.json
        case .daySealed(let p): p.json
        case .dayReopened(let p): p.json
        case .witness(let p): p.json
        case .genaiSession(let p): p.json
        case .genaiUsage(let p): p.json
        case .ingestRun(let p): p.json
        case .configClassifier(let p): p.json
        }
    }

    public init(type: String, data: JSONValue) throws(CadenceError) {
        switch type {
        case "ledger.genesis": self = .genesis(try Genesis(json: data))
        case "day.started": self = .dayStarted(try DayMark(data, owner: type))
        case "day.ended": self = .dayEnded(try DayMark(data, owner: type))
        case "presence.span": self = .presenceSpan(try PresenceSpanPayload(json: data))
        case "day.declared": self = .dayDeclared(try DayDeclared(json: data))
        case "day.noted": self = .dayNoted(try DayNoted(json: data))
        case "plan.added": self = .planAdded(try EventPayload.decodePlanTask(data))
        case "plan.updated":
            self = .planUpdated(try Changes(json: data, allowed: Changes.planFields, owner: type))
        case "plan.resolved": self = .planResolved(try PlanResolved(json: data))
        case "plan.committed": self = .planCommitted(try PlanCommitted(json: data))
        case "entry.created": self = .entryCreated(try EventPayload.decodeEntry(data))
        case "entry.updated":
            self = .entryUpdated(try Changes(json: data, allowed: Changes.entryFields, owner: type))
        case "entry.status": self = .entryStatus(try EntryStatusChange(json: data))
        case "day.sealed": self = .daySealed(try DaySealed(json: data))
        case "day.reopened": self = .dayReopened(try DayReopened(json: data))
        case "witness.checkpoint": self = .witness(try WitnessCheckpoint(json: data))
        case "genai.session": self = .genaiSession(try GenAISession(json: data))
        case "genai.usage": self = .genaiUsage(try GenAIUsage(json: data))
        case "ingest.run": self = .ingestRun(try IngestRun(json: data))
        case "config.classifier": self = .configClassifier(try ConfigClassifier(json: data))
        default: throw .validation("unknown event type '\(type)'")
        }
    }

    /// The subject string for this payload (for example "day:2026-10-29"). Task, entry and run payloads
    /// that do not carry their own id (updates, resolutions, status changes, runs) use `id`.
    public func subject(id: String?) -> String? {
        switch self {
        case .genesis: return "ledger"
        case .dayStarted(let p), .dayEnded(let p): return "day:\(p.day)"
        case .presenceSpan(let p): return "day:\(p.day)"
        case .dayDeclared(let p): return "day:\(p.day)"
        case .dayNoted(let p): return "day:\(p.day)"
        case .planAdded(let p): return "task:\(p.id)"
        case .planUpdated, .planResolved: return id.map { "task:\($0)" }
        case .planCommitted(let p): return "day:\(p.day)"
        case .entryCreated(let p): return "entry:\(p.id)"
        case .entryUpdated, .entryStatus: return id.map { "entry:\($0)" }
        case .daySealed(let p): return "day:\(p.day)"
        case .dayReopened(let p): return "day:\(p.day)"
        case .witness(let p): return "day:\(p.day)"
        case .genaiSession(let p): return "session:\(p.sessionId)"
        case .genaiUsage(let p): return "usage:\(p.day):\(p.tool):\(p.model):\(p.source)"
        case .ingestRun: return id.map { "run:\($0)" }
        case .configClassifier: return "config"
        }
    }

    public func draft(actor: Actor, id: String? = nil) -> EventDraft {
        EventDraft(type: type, subject: subject(id: id), data: data, actor: actor)
    }

    // PlanTask and Entry decode leniently (defaults for missing fields). As ledger payloads they must be
    // complete and in canonical form, so the decoded value has to encode back to exactly what came in.
    private static func decodePlanTask(_ data: JSONValue) throws(CadenceError) -> PlanTask {
        let task = try PlanTask(json: data)
        guard task.status == .open else { throw .validation("plan.added.status: must be 'open'") }
        guard LocalDate(task.day) != nil else { throw .validation("plan.added.day: must be a date as YYYY-MM-DD") }
        guard Timestamp.parse(task.plannedAt) != nil else {
            throw .validation("plan.added.planned_at: must be an RFC 3339 time")
        }
        guard task.resolvedAt == nil, task.reason == nil, task.reasonNote == nil, task.linkedEntries.isEmpty else {
            throw .validation("plan.added: an open task has no resolution, reason or linked entries")
        }
        try validateTaskFields(task, owner: "plan.added")
        try requireCanonical(task.json, data, owner: "plan.added")
        return task
    }

    /// Field rules shared by `plan.added` and the task a `plan.updated` produces.
    static func validateTaskFields(_ task: PlanTask, owner: String) throws(CadenceError) {
        guard isTitle(task.title) else { throw .validation("\(owner).title: must be 1 to 500 characters without control characters") }
        guard task.position >= 0 else { throw .validation("\(owner).position: must not be negative") }
        if let m = task.estimateMin, m < 0 { throw .validation("\(owner).estimate_min: must not be negative") }
    }

    /// Checks a task a `plan.updated` produced: the stored task with the changes applied must still be
    /// a complete, canonical task that passes the `plan.added` field rules.
    static func validatedUpdatedTask(_ data: JSONValue) throws(CadenceError) -> PlanTask {
        let task = try PlanTask(json: data)
        try validateTaskFields(task, owner: "plan.updated")
        try requireCanonical(task.json, data, owner: "plan.updated")
        return task
    }

    private static func decodeEntry(_ data: JSONValue) throws(CadenceError) -> Entry {
        try validatedEntry(data, owner: "entry.created")
    }

    /// The rules for a stored entry, used by `entry.created` and for the entry an `entry.updated`
    /// produces, so an update can never leave a row that `entry.created` would refuse.
    static func validatedEntry(_ data: JSONValue, owner: String) throws(CadenceError) -> Entry {
        let entry = try Entry(json: data)
        guard LocalDate(entry.day) != nil else { throw .validation("\(owner).day: must be a date as YYYY-MM-DD") }
        guard isTitle(entry.title) else { throw .validation("\(owner).title: must be 1 to 500 characters without control characters") }
        if let t = entry.occurredAt, Timestamp.parse(t) == nil {
            throw .validation("\(owner).occurred_at: must be an RFC 3339 time")
        }
        if let d = entry.durationS, d < 0 { throw .validation("\(owner).duration_s: must not be negative") }
        guard entry.quantity >= 0 else { throw .validation("\(owner).quantity: must not be negative") }
        for link in entry.links {
            let url = link.url.lowercased()
            guard url.hasPrefix("https://") || url.hasPrefix("http://") else {
                throw .validation("\(owner).links: only http and https links are stored")
            }
        }
        // Section 10.2: attrs is flat and holds strings, integers and booleans.
        for (key, value) in entry.attrs {
            switch value {
            case .string, .int, .bool: continue
            default: throw .validation("\(owner).attrs.\(key): must be a string, integer or boolean")
            }
        }
        try requireCanonical(entry.json, data, owner: owner)
        return entry
    }

    static func isTitle(_ text: String) -> Bool {
        (1...500).contains(text.count)
            && !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static let zoneCache = ZoneCache()

    static func isZone(_ name: String) -> Bool { zoneCache.isKnown(name) }

    /// Whether `instant` can belong to workday `day` in `tz` for any day boundary (00:00 to 23:59):
    /// its local date is the day itself or the next one. The boundary is config, and payloads are
    /// checked without config, so this is the widest window any boundary allows.
    static func isWithinWorkday(_ instant: String, day: String, tz: String) -> Bool {
        guard let date = Timestamp.parse(instant), let local = LocalDate(day), let zone = TimeZone(identifier: tz) else {
            return false
        }
        let days = LocalDate.floorDiv(Timestamp.localSeconds(date, in: zone), 86_400)
        return days == local.epochDays || days == local.epochDays + 1
    }

    private static func requireCanonical(_ encoded: JSONValue, _ input: JSONValue, owner: String)
        throws(CadenceError)
    {
        guard let want = encoded.objectValue, let got = input.objectValue else { return }
        for key in want.keys.sorted() where got[key] == nil { throw .validation("\(owner).\(key): is required") }
        for key in got.keys.sorted() where want[key] == nil { throw .validation("\(owner).\(key): unknown key") }
        for key in want.keys.sorted() where want[key] != got[key] {
            throw .validation("\(owner).\(key): is not in canonical form")
        }
    }
}

/// `TimeZone(identifier:)` is slow enough to matter during a rebuild, so answers are cached.
final class ZoneCache: @unchecked Sendable {
    private let lock = NSLock()
    private var known: [String: Bool] = [:]

    func isKnown(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let answer = known[name] { return answer }
        // Only IANA names: TimeZone also accepts abbreviations such as "IST" that mean different zones.
        let answer = name.contains("/") || name == "UTC" ? TimeZone(identifier: name) != nil : false
        known[name] = answer
        return answer
    }
}
