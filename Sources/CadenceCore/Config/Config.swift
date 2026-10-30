import Foundation

/// `config.json`, format `config/1` (docs/SPEC.md sections 7.4 and 10.2). Parsing is strict: unknown keys
/// are rejected so a typo cannot silently fall back to a default, and every failure is a
/// `CadenceError.validation` whose text starts with a JSON-path-like location.
public struct Config: Sendable, Equatable {
    public static let format = "config/1"

    public struct Profile: Sendable, Equatable {
        public var name: String?
        public var role: String?
        public var timezone: String
        public var backfillFrom: LocalDate?

        public init(name: String? = nil, role: String? = nil, timezone: String, backfillFrom: LocalDate? = nil) {
            self.name = name
            self.role = role
            self.timezone = timezone
            self.backfillFrom = backfillFrom
        }
    }

    public struct Reminder: Sendable, Equatable {
        public enum Kind: String, Sendable { case plan, wrap }
        public var kind: Kind
        /// "HH:MM".
        public var at: String?
        /// "dayStart+2m" or "dayStart+1h".
        public var after: String?

        public init(kind: Kind, at: String? = nil, after: String? = nil) {
            self.kind = kind
            self.at = at
            self.after = after
        }
    }

    public struct Team: Sendable, Equatable {
        public var timezone: String?
        public var hours: [String]

        public init(timezone: String? = nil, hours: [String]) {
            self.timezone = timezone
            self.hours = hours
        }
    }

    public enum Sounds: String, Sendable { case off, subtle, full }

    public struct ClaudeCode: Sendable, Equatable {
        public var injectPlanAtSessionStart: Bool
        public var projectsDir: String

        public init(injectPlanAtSessionStart: Bool = true, projectsDir: String = "~/.claude/projects") {
            self.injectPlanAtSessionStart = injectPlanAtSessionStart
            self.projectsDir = projectsDir
        }
    }

    public struct Privacy: Sendable, Equatable {
        public var notificationTitles: Bool
        public var exportSpans: Bool
        public var projectAliases: Bool

        public init(notificationTitles: Bool = false, exportSpans: Bool = false, projectAliases: Bool = true) {
            self.notificationTitles = notificationTitles
            self.exportSpans = exportSpans
            self.projectAliases = projectAliases
        }
    }

    public struct Collector: Sendable, Equatable {
        public var name: String
        public var enabled: Bool
        /// "github" or "claude-code-transcripts".
        public var builtin: String?
        /// argv; `command[0]` is an absolute path.
        public var command: [String]?
        /// Keys match `^[A-Z_][A-Z0-9_]*$` and are never PATH, HOME, LANG or TZ (those are fixed).
        public var env: [String: String]
        /// Absolute path, github builtin only.
        public var gh: String?
        /// Relative to the Cadence maps folder, or absolute.
        public var map: String?
        /// "15m", "30m", "1h", "60m"; minimum 15m.
        public var every: String?
        /// "HH:MM" list.
        public var at: [String]

        public init(
            name: String, enabled: Bool = true, builtin: String? = nil, command: [String]? = nil,
            env: [String: String] = [:], gh: String? = nil, map: String? = nil, every: String? = nil,
            at: [String] = []
        ) {
            self.name = name
            self.enabled = enabled
            self.builtin = builtin
            self.command = command
            self.env = env
            self.gh = gh
            self.map = map
            self.every = every
            self.at = at
        }

        /// `every` in minutes, if set and well formed.
        public var everyMinutes: Int? { every.flatMap { Config.parseEvery($0) } }
    }

    public struct GenAI: Sendable, Equatable {
        public var priority: [String]
        public var prices: [String: JSONValue]?

        public init(priority: [String] = Config.defaultPriority, prices: [String: JSONValue]? = nil) {
            self.priority = priority
            self.prices = prices
        }
    }

    public var profile: Profile
    public var workdays: [Weekday]
    public var dayBoundary: DayBoundary
    public var reminders: [Reminder]
    public var tickets: TicketRules
    public var team: Team?
    public var sounds: Sounds
    public var claudeCode: ClaudeCode
    public var privacy: Privacy
    /// Sorted by name.
    public var collectors: [Collector]
    /// Extra hosts allowed for http links (docs/SPEC.md section 10.1).
    public var hosts: [String]
    public var aiMarkers: [String]
    public var genai: GenAI
    public var signals: [String]

    public static let defaultPriority = ["endpoint", "transcripts", "import"]
    public static let defaultAIMarkers = ["Generated with Claude Code", "Co-Authored-By: Claude"]
    public static let defaultSignals = [
        "discussion.raised", "decision.challenged", "meeting.led", "mentoring", "initiative.started",
        "incident.handled",
    ]
    public static let defaultReminders: [Reminder] = [
        Reminder(kind: .plan, after: "dayStart+2m"), Reminder(kind: .wrap, at: "17:30"),
    ]

    public static func defaults(timezone: String) -> Config {
        Config(
            profile: Profile(timezone: timezone),
            workdays: [.mon, .tue, .wed, .thu, .fri],
            dayBoundary: .standard,
            reminders: defaultReminders,
            tickets: .standard,
            team: nil,
            sounds: .subtle,
            claudeCode: ClaudeCode(),
            privacy: Privacy(),
            collectors: [],
            hosts: [],
            aiMarkers: defaultAIMarkers,
            genai: GenAI(),
            signals: defaultSignals
        )
    }

    /// Parses and validates config/1 JSON text. `fallbackZone` stands in for a missing `profile.timezone`.
    public static func parse(_ text: String, fallbackZone: String? = nil) throws(CadenceError) -> Config {
        try parse(bytes: Array(text.utf8), fallbackZone: fallbackZone)
    }

    /// As `parse(_:fallbackZone:)`, for raw file bytes. Errors never quote the input.
    public static func parse(bytes: [UInt8], fallbackZone: String? = nil) throws(CadenceError) -> Config {
        let value: JSONValue
        do {
            value = try JSONParser.parse(bytes: bytes)
        } catch {
            throw .validation("config is not valid JSON: \(describe(error))")
        }
        return try Config(validating: value, fallbackZone: fallbackZone)
    }

    static func describe(_ failure: JSONParser.Failure) -> String {
        switch failure {
        case .invalidUTF8: "the file is not valid UTF-8"
        case .unexpectedEnd: "unexpected end of input"
        case .unexpectedByte(_, let offset): "unexpected character at byte \(offset)"
        case .floatNotAllowed(let offset): "numbers with a fraction or exponent are not allowed (byte \(offset))"
        case .integerOutOfRange(let offset): "integer out of range (byte \(offset))"
        case .invalidEscape(let offset): "invalid escape at byte \(offset)"
        case .unpairedSurrogate(let offset): "unpaired surrogate at byte \(offset)"
        case .controlCharacterInString(let offset): "control character in a string at byte \(offset)"
        case .duplicateKey: "an object repeats a key"
        case .trailingContent(let offset): "extra content after the value at byte \(offset)"
        case .tooDeep: "nested too deeply"
        }
    }

    /// "15m", "1h": minutes, or nil when malformed.
    static func parseEvery(_ text: String) -> Int? {
        guard let unit = text.last, unit == "m" || unit == "h" else { return nil }
        let digits = text.dropLast()
        guard (1...4).contains(digits.utf8.count), digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
            let n = Int(digits)
        else { return nil }
        return unit == "h" ? n * 60 : n
    }

    static func isClock(_ text: String) -> Bool { Timestamp.parseClock(text) != nil }
}
