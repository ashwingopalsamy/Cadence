import Foundation
import Testing

@testable import CadenceCore

@Suite struct ConfigTests {
    static let exampleURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("examples/config.example.json")

    static func example() throws -> String { try String(contentsOf: exampleURL, encoding: .utf8) }

    static let minimal = #"{"cadence":"config/1","profile":{"timezone":"Asia/Kolkata"}}"#

    /// A minimal config with one extra top-level fragment, for example `"sounds":"loud"`.
    static func with(_ fragment: String) -> String {
        #"{"cadence":"config/1","profile":{"timezone":"Asia/Kolkata"},"# + fragment + "}"
    }

    static func collector(_ body: String, name: String = "demo") -> String {
        with(#""collectors":{"\#(name)":{\#(body)}}"#)
    }

    func message(_ text: String) -> String? {
        do {
            _ = try Config.parse(text)
            return nil
        } catch {
            if case .validation(let m) = error { return m }
            return "wrong error: \(error)"
        }
    }

    func tempDir() throws -> URL {
        let dir = TestStore.tempDirectory("config")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Example and defaults

    @Test func exampleLoadsAndEqualsExpected() throws {
        let config = try Config.parse(Self.example())
        var expected = Config.defaults(timezone: "Asia/Kolkata")
        expected.profile = .init(name: "Your Name", role: "Software Engineer", timezone: "Asia/Kolkata", backfillFrom: nil)
        expected.tickets = TicketRules(
            pattern: TicketRules.defaultPattern, titleWindow: 12, selfInitiated: "^0+$",
            linkTemplate: "https://tickets.example.com/browse/{key}")
        expected.team = .init(timezone: "America/Sao_Paulo", hours: ["09:00", "18:00"])
        expected.collectors = [
            .init(name: "claude-code", enabled: true, builtin: "claude-code-transcripts", command: nil, env: [:], gh: nil, map: nil, every: "60m", at: []),
            .init(
                name: "genai-endpoint", enabled: false, builtin: nil,
                command: ["/usr/bin/curl", "-fsS", "--max-time", "20", "http://127.0.0.1:PORT/usage?from={since}&to={until}"],
                env: [:], gh: nil, map: "maps/genai-endpoint.json", every: nil, at: ["17:10"]),
            .init(name: "github", enabled: true, builtin: "github", command: nil, env: ["GH_HOST": "git.example.com"], gh: "/opt/homebrew/bin/gh", map: nil, every: "30m", at: []),
        ]
        #expect(config == expected)
    }

    @Test func roundTrips() throws {
        let config = try Config.parse(Self.example())
        let text = try CanonicalJSON.string(config.json)
        #expect(try Config.parse(text) == config)
        let d = Config.defaults(timezone: "UTC")
        #expect(try Config.parse(CanonicalJSON.string(d.json)) == d)
    }

    @Test func defaultsWhenKeysMissing() throws {
        let config = try Config.parse(Self.minimal)
        #expect(config == Config.defaults(timezone: "Asia/Kolkata"))
        #expect(config.workdays == [.mon, .tue, .wed, .thu, .fri])
        #expect(config.dayBoundary == DayBoundary.standard)
        #expect(config.reminders == [.init(kind: .plan, at: nil, after: "dayStart+2m"), .init(kind: .wrap, at: "17:30", after: nil)])
        #expect(config.tickets == TicketRules.standard)
        #expect(config.team == nil)
        #expect(config.sounds == .subtle)
        #expect(config.claudeCode == .init(injectPlanAtSessionStart: true, projectsDir: "~/.claude/projects"))
        #expect(config.privacy == .init(notificationTitles: false, exportSpans: false, projectAliases: true))
        #expect(config.collectors.isEmpty)
        #expect(config.hosts.isEmpty)
        #expect(config.aiMarkers == ["Generated with Claude Code", "Co-Authored-By: Claude"])
        #expect(config.genai.priority == ["endpoint", "transcripts", "import"])
        #expect(config.genai.prices == nil)
        #expect(config.genai.standupLine == false)
        #expect(config.signals.count == 6)
        #expect(config.profile.backfillFrom == nil)
    }

    @Test func fallbackZoneAndMissingZone() throws {
        let text = #"{"cadence":"config/1"}"#
        #expect(message(text) == "profile.timezone: required")
        #expect(try Config.parse(text, fallbackZone: "UTC").profile.timezone == "UTC")
    }

    @Test func optionalSectionsParse() throws {
        let text =
            #"{"cadence":"config/1","profile":{"timezone":"UTC","backfillFrom":"2026-10-01"},"hosts":["git.example.com"],"#
            + #""ai":{"markers":["Made by tool"]},"genai":{"priority":["import","endpoint"],"prices":{"m1":{"in":3}}},"signals":["mentoring"]}"#
        let config = try Config.parse(text)
        #expect(config.hosts == ["git.example.com"])
        #expect(config.aiMarkers == ["Made by tool"])
        #expect(config.genai.priority == ["import", "endpoint"])
        #expect(config.genai.prices == ["m1": ["in": 3]])
        #expect(config.signals == ["mentoring"])
        #expect(config.profile.backfillFrom == LocalDate("2026-10-01"))
        #expect(try Config.parse(CanonicalJSON.string(config.json)) == config)
    }

    @Test func theStandupAILineIsOffUntilSwitchedOn() throws {
        let defaults = Config.defaults(timezone: "UTC")
        #expect(defaults.genai.standupLine == false)
        #expect(try defaults.value(at: "genai.standupLine") == .bool(false))
        let on = try Config.parse(#"{"cadence":"config/1","profile":{"timezone":"UTC"},"genai":{"standupLine":true}}"#)
        #expect(on.genai.standupLine == true && on.genai.priority == Config.defaultPriority)
        #expect(try Config.parse(CanonicalJSON.string(on.json)) == on)
        let set = try defaults.setting("genai.standupLine", to: "true")
        #expect(set.genai.standupLine == true)
        #expect(try set.setting("genai.standupLine", to: "false").genai.standupLine == false)
        // null puts the default back.
        #expect(try set.setting("genai.standupLine", to: "null").genai.standupLine == false)
    }

    // MARK: Validation

    struct Bad: Sendable, CustomTestStringConvertible {
        let text: String
        let expected: String
        var testDescription: String { expected }
    }

    static let bad: [Bad] = [
        Bad(text: #"{"cadence":"config/2","profile":{"timezone":"UTC"}}"#, expected: "cadence: must be \"config/1\""),
        Bad(text: #"{"profile":{"timezone":"UTC"}}"#, expected: "cadence: must be \"config/1\""),
        Bad(text: with(#""colour":"blue""#), expected: "colour: unknown key"),
        Bad(text: #"{"cadence":"config/1","profile":{"timezone":"Mars/Base"}}"#, expected: "profile.timezone: not a time zone: Mars/Base"),
        Bad(text: #"{"cadence":"config/1","profile":{"timezone":"UTC","backfillFrom":"2026-13-01"}}"#, expected: "profile.backfillFrom: must be a date like 2026-10-01"),
        Bad(text: with(#""workdays":[]"#), expected: "workdays: must not be empty"),
        Bad(text: with(#""workdays":["mon","tue","mon"]"#), expected: "workdays[2]: duplicate \"mon\""),
        Bad(text: with(#""workdays":["mon","funday"]"#), expected: "workdays[1]: must be one of mon, tue, wed, thu, fri, sat, sun"),
        Bad(text: with(#""dayBoundary":"4am""#), expected: "dayBoundary: must be HH:MM"),
        Bad(text: with(#""reminders":[{"kind":"plan","at":"25:00"}]"#), expected: "reminders[0].at: must be HH:MM"),
        Bad(text: with(#""reminders":[{"kind":"plan","after":"dayStart+2x"}]"#), expected: "reminders[0].after: must look like dayStart+2m or dayStart+1h"),
        Bad(text: with(#""reminders":[{"kind":"nap","at":"09:00"}]"#), expected: "reminders[0].kind: must be one of plan, wrap"),
        Bad(text: with(#""reminders":[{"kind":"plan"}]"#), expected: "reminders[0]: needs exactly one of at or after"),
        Bad(text: with(#""reminders":[{"kind":"plan","at":"09:00","after":"dayStart+2m"}]"#), expected: "reminders[0]: needs exactly one of at or after"),
        Bad(text: with(#""tickets":{"pattern":"("}"#), expected: "tickets.pattern is not a valid regular expression: ("),
        Bad(text: with(#""tickets":{"titleWindow":0}"#), expected: "tickets.titleWindow must be between 1 and 200, got 0"),
        Bad(text: with(#""tickets":{"titleWindow":"12"}"#), expected: "tickets.titleWindow: must be an integer"),
        Bad(text: with(#""team":{"timezone":"UTC","hours":["09:00"]}"#), expected: "team.hours: must be two times like [\"09:00\", \"18:00\"]"),
        Bad(text: with(#""sounds":"loud""#), expected: "sounds: must be one of off, subtle, full"),
        Bad(text: with(#""privacy":{"notificationTitles":"no"}"#), expected: "privacy.notificationTitles: must be true or false"),
        Bad(text: collector(#""builtin":"github","command":["/bin/true"]"#), expected: "collectors.demo: needs exactly one of builtin or command"),
        Bad(text: collector(#""enabled":true"#), expected: "collectors.demo: needs exactly one of builtin or command"),
        Bad(text: collector(#""builtin":"ftp""#), expected: "collectors.demo.builtin: must be one of github, claude-code-transcripts"),
        Bad(text: collector(#""command":[]"#), expected: "collectors.demo.command: must not be empty"),
        Bad(text: collector(#""command":["curl","-s"]"#), expected: "collectors.demo.command[0]: must be an absolute path"),
        Bad(text: collector(#""command":["/usr/bin/curl",5]"#), expected: "collectors.demo.command[1]: must be a string"),
        Bad(text: collector(#""command":["/bin/true"],"gh":"/usr/bin/gh""#), expected: "collectors.demo.gh: only allowed on the github builtin"),
        Bad(text: collector(#""builtin":"github","gh":"gh""#), expected: "collectors.demo.gh: must be an absolute path"),
        Bad(text: collector(#""builtin":"github","every":"5m""#), expected: "collectors.demo.every: must be at least 15m"),
        Bad(text: collector(#""builtin":"github","every":"soon""#), expected: "collectors.demo.every: must look like 15m or 1h"),
        Bad(text: collector(#""builtin":"github","at":["7pm"]"#), expected: "collectors.demo.at[0]: must be HH:MM"),
        Bad(text: collector(#""builtin":"github","env":{"gh_host":"x"}"#), expected: "collectors.demo.env.gh_host: key must match ^[A-Z_][A-Z0-9_]*$"),
        Bad(text: collector(#""builtin":"github","env":{"PATH":"/tmp"}"#), expected: "collectors.demo.env.PATH: reserved; Cadence sets PATH, HOME, LANG and TZ itself"),
        Bad(text: collector(#""builtin":"github","env":{"HOME":"/tmp"}"#), expected: "collectors.demo.env.HOME: reserved; Cadence sets PATH, HOME, LANG and TZ itself"),
        Bad(text: collector(#""builtin":"github","env":{"TZ":"UTC"}"#), expected: "collectors.demo.env.TZ: reserved; Cadence sets PATH, HOME, LANG and TZ itself"),
        Bad(text: collector(#""builtin":"github","env":{"A":1}"#), expected: "collectors.demo.env.A: must be a string"),
        Bad(text: collector(#""builtin":"github""#, name: "Bad_Name"), expected: "collectors.Bad_Name: name must match ^[a-z0-9-]{1,64}$"),
        Bad(text: collector(#""builtin":"github","colour":1"#), expected: "collectors.demo.colour: unknown key"),
        Bad(text: with(#""genai":{"priority":["endpoint","guess"]}"#), expected: "genai.priority[1]: must be one of endpoint, transcripts, import"),
        Bad(text: with(#""genai":{"priority":["import","import"]}"#), expected: "genai.priority[1]: duplicate \"import\""),
        Bad(text: with(#""genai":{"prices":[]}"#), expected: "genai.prices: must be an object"),
        Bad(text: with(#""genai":{"standupLine":"yes"}"#), expected: "genai.standupLine: must be true or false"),
        Bad(text: with(#""genai":{"standupline":true}"#), expected: "genai.standupline: unknown key"),
        Bad(text: with(#""ai":{"markers":[3]}"#), expected: "ai.markers[0]: must be a string"),
        Bad(text: with(#""hosts":"git.example.com""#), expected: "hosts: must be an array of strings"),
    ]

    @Test(arguments: bad)
    func rejects(_ b: Bad) {
        #expect(message(b.text) == b.expected)
    }

    @Test func notJSONDoesNotEchoContents() {
        let m = message("not json SECRET-TOKEN-123 {")
        #expect(m?.hasPrefix("config is not valid JSON") == true)
        #expect(m?.contains("SECRET") == false)
        let m2 = message(#"{"cadence":"config/1","token":"SECRET-TOKEN-123""#)
        #expect(m2?.contains("SECRET") == false)
        #expect(message("[1]") == "config: must be a JSON object")
    }

    // MARK: Get and set

    @Test func valueAt() throws {
        let config = try Config.parse(Self.example())
        #expect(try config.value(at: "dayBoundary") == "04:00")
        #expect(try config.value(at: "tickets.titleWindow") == 12)
        #expect(try config.value(at: "sounds") == "subtle")
        #expect(try config.value(at: "profile.timezone") == "Asia/Kolkata")
        #expect(try config.value(at: "reminders.1.at") == "17:30")
        #expect(try config.value(at: "collectors.github.env.GH_HOST") == "git.example.com")
        #expect(try config.value(at: "reminders").arrayValue?.count == 2)
        #expect(try config.value(at: "").objectValue != nil)
        #expect(throws: CadenceError.notFound("config key not found: nope.deeper")) { try config.value(at: "nope.deeper") }
        #expect(throws: CadenceError.notFound("config key not found: profile.backfillFrom")) { try config.value(at: "profile.backfillFrom") }
    }

    @Test func settingNested() throws {
        let config = try Config.parse(Self.example())
        let a = try config.setting("tickets.titleWindow", to: "20")
        #expect(a.tickets.titleWindow == 20)
        #expect(a.sounds == config.sounds)
        let b = try config.setting("sounds", to: #""full""#)
        #expect(b.sounds == .full)
        let c = try config.setting("sounds", to: "off")  // a bare word is taken as a string
        #expect(c.sounds == .off)
        let d = try config.setting("dayBoundary", to: "05:30")
        #expect(d.dayBoundary == DayBoundary("05:30"))
        let e = try config.setting("reminders", to: #"[{"kind":"wrap","at":"18:00"}]"#)
        #expect(e.reminders == [.init(kind: .wrap, at: "18:00", after: nil)])
        let f = try config.setting("collectors.github.every", to: #""1h""#)
        #expect(f.collectors.first { $0.name == "github" }?.every == "1h")
        let g = try config.setting("profile.backfillFrom", to: #""2026-10-01""#)
        #expect(g.profile.backfillFrom == LocalDate("2026-10-01"))
        let h = try g.setting("profile.backfillFrom", to: "null")
        #expect(h.profile.backfillFrom == nil)
        let i = try config.setting("team", to: "null")
        #expect(i.team == nil)
        let j = try config.setting("reminders.1.at", to: #""18:15""#)
        #expect(j.reminders[1].at == "18:15")
        let k = try config.setting("collectors.extra", to: #"{"builtin":"github"}"#)
        #expect(k.collectors.map(\.name) == ["claude-code", "extra", "genai-endpoint", "github"])
    }

    @Test func settingInvalidIsRejected() throws {
        let config = try Config.parse(Self.example())
        #expect(throws: CadenceError.validation("sounds: must be one of off, subtle, full")) {
            try config.setting("sounds", to: #""loud""#)
        }
        #expect(throws: CadenceError.validation("collectors.github.every: must be at least 15m")) {
            try config.setting("collectors.github.every", to: #""5m""#)
        }
        #expect(throws: CadenceError.validation("colour: unknown key")) { try config.setting("colour", to: "1") }
        #expect(throws: CadenceError.validation("workdays: must not be empty")) { try config.setting("workdays", to: "[]") }
        #expect(throws: CadenceError.notFound("config key not found: reminders.9.at")) {
            try config.setting("reminders.9.at", to: #""09:00""#)
        }
        #expect(throws: CadenceError.validation("cadence: cannot be changed")) { try config.setting("cadence", to: #""config/2""#) }
    }

    // MARK: Files

    @Test func missingFileGivesDefaults() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (config, check) = try ConfigStore.load(from: dir.appendingPathComponent("config.json"), fallbackZone: "Europe/Berlin")
        #expect(config == Config.defaults(timezone: "Europe/Berlin"))
        #expect(!check.exists)
        #expect(!check.safe)
        #expect(check.problem == nil)
    }

    @Test func ownerAndModeCheck() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Self.minimal.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o600)
        var (config, check) = try ConfigStore.load(from: url, fallbackZone: "UTC")
        #expect(config.profile.timezone == "Asia/Kolkata")
        #expect(check.exists && check.ownedByUser && check.mode == 0o600 && check.safe && check.problem == nil)

        chmod(url.path, 0o644)
        (config, check) = try ConfigStore.load(from: url, fallbackZone: "UTC")
        #expect(!check.safe && check.ownedByUser && check.mode == 0o644)
        #expect(check.problem?.contains("0644") == true)
        #expect(check.problem?.contains("chmod 600") == true)
        #expect(check.problem?.contains("Asia/Kolkata") == false)
        chmod(url.path, 0o640)
        #expect(!ConfigStore.check(url).safe)
        chmod(url.path, 0o400)
        #expect(ConfigStore.check(url).safe)
    }

    @Test func badFileErrorDoesNotEchoContents() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try "SECRET-TOKEN-123".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o600)
        do {
            _ = try ConfigStore.load(from: url, fallbackZone: "UTC")
            Issue.record("expected a throw")
        } catch {
            #expect(error.message.contains("SECRET") == false)
            #expect(error.message.hasPrefix("config is not valid JSON"))
        }
    }

    @Test func saveWritesPrivateAtomicFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("Cadence")
        let url = sub.appendingPathComponent("config.json")
        let config = try Config.parse(Self.example())
        try ConfigStore.save(config, to: url)
        let check = ConfigStore.check(url)
        #expect(check.safe && check.mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sub.path) == ["config.json"])
        #expect(try ConfigStore.load(from: url, fallbackZone: "UTC").0 == config)
        // Overwrite keeps 0600 and leaves nothing behind.
        try ConfigStore.save(config.setting("sounds", to: "full"), to: url)
        #expect(ConfigStore.check(url).mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sub.path) == ["config.json"])
        #expect(try ConfigStore.load(from: url, fallbackZone: "UTC").0.sounds == .full)
    }
}
