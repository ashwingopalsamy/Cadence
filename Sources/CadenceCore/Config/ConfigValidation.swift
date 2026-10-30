import Foundation

// Validation of a parsed JSON tree into `Config`. Each helper takes the JSON-path-like location it is
// reading, so every error starts with where the problem is.

private func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

private func fail(_ path: String, _ message: String) -> CadenceError { .validation("\(path): \(message)") }

private func object(_ value: JSONValue, _ path: String, allowed: [String]) throws(CadenceError) -> [String: JSONValue] {
    guard case .object(let members) = value else { throw fail(path.isEmpty ? "config" : path, "must be a JSON object") }
    let bytewise: (String, String) -> Bool = { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    for key in members.keys.sorted(by: bytewise) where !allowed.contains(key) {
        throw fail(join(path, key), "unknown key")
    }
    return members
}

private func string(_ value: JSONValue, _ path: String) throws(CadenceError) -> String {
    guard case .string(let s) = value else { throw fail(path, "must be a string") }
    return s
}

private func optionalString(_ members: [String: JSONValue], _ key: String, _ path: String) throws(CadenceError) -> String? {
    guard let v = members[key], !v.isNull else { return nil }
    return try string(v, join(path, key))
}

private func bool(_ members: [String: JSONValue], _ key: String, _ path: String, default d: Bool) throws(CadenceError) -> Bool {
    guard let v = members[key], !v.isNull else { return d }
    guard case .bool(let b) = v else { throw fail(join(path, key), "must be true or false") }
    return b
}

private func strings(_ value: JSONValue, _ path: String) throws(CadenceError) -> [String] {
    guard case .array(let items) = value else { throw fail(path, "must be an array of strings") }
    var out: [String] = []
    for (i, item) in items.enumerated() { out.append(try string(item, "\(path)[\(i)]")) }
    return out
}

private func optionalStrings(_ members: [String: JSONValue], _ key: String, _ path: String) throws(CadenceError) -> [String]? {
    guard let v = members[key], !v.isNull else { return nil }
    return try strings(v, join(path, key))
}

private func clock(_ text: String, _ path: String) throws(CadenceError) {
    guard Config.isClock(text) else { throw fail(path, "must be HH:MM") }
}

private func timeZone(_ id: String, _ path: String) throws(CadenceError) {
    guard !id.isEmpty, TimeZone(identifier: id) != nil else { throw fail(path, "not a time zone: \(id)") }
}

extension Config {
    static let reservedEnv: Set<String> = ["PATH", "HOME", "LANG", "TZ"]
    static let builtins = ["github", "claude-code-transcripts"]

    init(validating root: JSONValue, fallbackZone: String?) throws(CadenceError) {
        let top = try object(
            root, "",
            allowed: [
                "cadence", "profile", "workdays", "dayBoundary", "reminders", "tickets", "team", "sounds",
                "claudeCode", "privacy", "collectors", "hosts", "ai", "genai", "signals",
            ])
        guard top["cadence"] == .string(Config.format) else { throw fail("cadence", "must be \"\(Config.format)\"") }

        // profile
        var profileMembers: [String: JSONValue] = [:]
        if let p = top["profile"], !p.isNull {
            profileMembers = try object(p, "profile", allowed: ["name", "role", "timezone", "backfillFrom"])
        }
        let zone: String
        if let z = profileMembers["timezone"], !z.isNull {
            zone = try string(z, "profile.timezone")
        } else if let fallbackZone {
            zone = fallbackZone
        } else {
            throw fail("profile.timezone", "required")
        }
        try timeZone(zone, "profile.timezone")
        var backfill: LocalDate?
        if let b = profileMembers["backfillFrom"], !b.isNull {
            guard let date = LocalDate(try string(b, "profile.backfillFrom")) else {
                throw fail("profile.backfillFrom", "must be a date like 2026-10-01")
            }
            backfill = date
        }
        var config = Config.defaults(timezone: zone)
        config.profile = Profile(
            name: try optionalString(profileMembers, "name", "profile"),
            role: try optionalString(profileMembers, "role", "profile"),
            timezone: zone, backfillFrom: backfill)

        if let v = top["workdays"], !v.isNull { config.workdays = try Config.workdays(v) }
        if let v = top["dayBoundary"], !v.isNull {
            guard let boundary = DayBoundary(try string(v, "dayBoundary")) else { throw fail("dayBoundary", "must be HH:MM") }
            config.dayBoundary = boundary
        }
        if let v = top["reminders"], !v.isNull { config.reminders = try Config.reminders(v) }
        if let v = top["tickets"], !v.isNull { config.tickets = try Config.tickets(v) }
        if let v = top["team"], !v.isNull { config.team = try Config.team(v) }
        if let v = top["sounds"], !v.isNull {
            guard let s = Sounds(rawValue: try string(v, "sounds")) else {
                throw fail("sounds", "must be one of off, subtle, full")
            }
            config.sounds = s
        }
        if let v = top["claudeCode"], !v.isNull {
            let m = try object(v, "claudeCode", allowed: ["injectPlanAtSessionStart", "projectsDir"])
            let dir = try optionalString(m, "projectsDir", "claudeCode") ?? config.claudeCode.projectsDir
            guard !dir.isEmpty else { throw fail("claudeCode.projectsDir", "must not be empty") }
            config.claudeCode = ClaudeCode(
                injectPlanAtSessionStart: try bool(m, "injectPlanAtSessionStart", "claudeCode", default: true),
                projectsDir: dir)
        }
        if let v = top["privacy"], !v.isNull {
            let m = try object(v, "privacy", allowed: ["notificationTitles", "exportSpans", "projectAliases"])
            config.privacy = Privacy(
                notificationTitles: try bool(m, "notificationTitles", "privacy", default: false),
                exportSpans: try bool(m, "exportSpans", "privacy", default: false),
                projectAliases: try bool(m, "projectAliases", "privacy", default: true))
        }
        if let v = top["collectors"], !v.isNull { config.collectors = try Config.collectors(v) }
        if let v = top["hosts"], !v.isNull {
            let hosts = try strings(v, "hosts")
            for (i, h) in hosts.enumerated()
            where h.isEmpty || h.contains("/") || h.unicodeScalars.contains(where: { $0.properties.isWhitespace }) {
                throw fail("hosts[\(i)]", "must be a host name")
            }
            config.hosts = hosts
        }
        if let v = top["ai"], !v.isNull {
            let m = try object(v, "ai", allowed: ["markers"])
            if let markers = try optionalStrings(m, "markers", "ai") { config.aiMarkers = markers }
        }
        if let v = top["genai"], !v.isNull { config.genai = try Config.genai(v) }
        if let v = top["signals"], !v.isNull {
            let signals = try strings(v, "signals")
            for (i, s) in signals.enumerated()
            where s.isEmpty || !s.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F })
            {
                throw fail("signals[\(i)]", "must be lowercase letters, digits, dots, dashes or underscores")
            }
            config.signals = signals
        }
        self = config
    }

    private static func workdays(_ value: JSONValue) throws(CadenceError) -> [Weekday] {
        guard case .array(let items) = value else { throw fail("workdays", "must be an array of weekday names") }
        guard !items.isEmpty else { throw fail("workdays", "must not be empty") }
        var out: [Weekday] = []
        for (i, item) in items.enumerated() {
            let name = try string(item, "workdays[\(i)]")
            guard let day = Weekday(rawValue: name) else {
                throw fail("workdays[\(i)]", "must be one of mon, tue, wed, thu, fri, sat, sun")
            }
            guard !out.contains(day) else { throw fail("workdays[\(i)]", "duplicate \"\(name)\"") }
            out.append(day)
        }
        return out
    }

    private static func reminders(_ value: JSONValue) throws(CadenceError) -> [Reminder] {
        guard case .array(let items) = value else { throw fail("reminders", "must be an array") }
        var out: [Reminder] = []
        for (i, item) in items.enumerated() {
            let path = "reminders[\(i)]"
            let m = try object(item, path, allowed: ["kind", "at", "after"])
            guard let kindValue = m["kind"], let kind = Reminder.Kind(rawValue: (try string(kindValue, "\(path).kind"))) else {
                throw fail("\(path).kind", "must be one of plan, wrap")
            }
            let at = try optionalString(m, "at", path)
            let after = try optionalString(m, "after", path)
            guard (at == nil) != (after == nil) else { throw fail(path, "needs exactly one of at or after") }
            if let at { try clock(at, "\(path).at") }
            if let after, !isDayStartOffset(after) {
                throw fail("\(path).after", "must look like dayStart+2m or dayStart+1h")
            }
            out.append(Reminder(kind: kind, at: at, after: after))
        }
        return out
    }

    /// "dayStart+Nm" or "dayStart+Nh", N up to four digits.
    static func isDayStartOffset(_ text: String) -> Bool {
        let prefix = "dayStart+"
        guard text.hasPrefix(prefix) else { return false }
        return parseEvery(String(text.dropFirst(prefix.count))).map { $0 > 0 } ?? false
    }

    private static func tickets(_ value: JSONValue) throws(CadenceError) -> TicketRules {
        let m = try object(value, "tickets", allowed: ["pattern", "titleWindow", "selfInitiated", "linkTemplate"])
        var rules = TicketRules.standard
        if let p = try optionalString(m, "pattern", "tickets") { rules.pattern = p }
        if let w = m["titleWindow"], !w.isNull {
            guard case .int(let n) = w else { throw fail("tickets.titleWindow", "must be an integer") }
            rules.titleWindow = Int(clamping: n)
        }
        if let s = try optionalString(m, "selfInitiated", "tickets") { rules.selfInitiated = s }
        rules.linkTemplate = try optionalString(m, "linkTemplate", "tickets")
        _ = try TicketClassifier(rules: rules)
        return rules
    }

    private static func team(_ value: JSONValue) throws(CadenceError) -> Team {
        let m = try object(value, "team", allowed: ["timezone", "hours"])
        let zone = try optionalString(m, "timezone", "team")
        if let zone { try timeZone(zone, "team.timezone") }
        guard let hoursValue = m["hours"] else { throw fail("team.hours", "required") }
        let hours = try strings(hoursValue, "team.hours")
        guard hours.count == 2 else { throw fail("team.hours", "must be two times like [\"09:00\", \"18:00\"]") }
        for (i, h) in hours.enumerated() { try clock(h, "team.hours[\(i)]") }
        return Team(timezone: zone, hours: hours)
    }

    private static func genai(_ value: JSONValue) throws(CadenceError) -> GenAI {
        let m = try object(value, "genai", allowed: ["priority", "prices"])
        var genai = GenAI()
        if let p = try optionalStrings(m, "priority", "genai") {
            guard !p.isEmpty else { throw fail("genai.priority", "must not be empty") }
            for (i, entry) in p.enumerated() {
                guard defaultPriority.contains(entry) else {
                    throw fail("genai.priority[\(i)]", "must be one of endpoint, transcripts, import")
                }
                guard !p[..<i].contains(entry) else { throw fail("genai.priority[\(i)]", "duplicate \"\(entry)\"") }
            }
            genai.priority = p
        }
        if let prices = m["prices"], !prices.isNull {
            guard case .object(let table) = prices else { throw fail("genai.prices", "must be an object") }
            genai.prices = table
        }
        return genai
    }

    private static func collectors(_ value: JSONValue) throws(CadenceError) -> [Collector] {
        guard case .object(let members) = value else { throw fail("collectors", "must be an object keyed by collector name") }
        var out: [Collector] = []
        for name in members.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            let path = "collectors.\(name)"
            guard (1...64).contains(name.utf8.count),
                name.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D })
            else { throw fail(path, "name must match ^[a-z0-9-]{1,64}$") }
            out.append(try collector(name: name, members[name] ?? .null, path))
        }
        return out
    }

    private static func collector(name: String, _ value: JSONValue, _ path: String) throws(CadenceError) -> Collector {
        let m = try object(value, path, allowed: ["enabled", "builtin", "command", "env", "gh", "map", "every", "at"])
        var c = Collector(name: name, enabled: try bool(m, "enabled", path, default: true))
        let hasBuiltin = !(m["builtin"] ?? .null).isNull
        let hasCommand = !(m["command"] ?? .null).isNull
        guard hasBuiltin != hasCommand else { throw fail(path, "needs exactly one of builtin or command") }
        if hasBuiltin {
            let b = try optionalString(m, "builtin", path) ?? ""
            guard builtins.contains(b) else { throw fail("\(path).builtin", "must be one of github, claude-code-transcripts") }
            c.builtin = b
        } else if let commandValue = m["command"] {
            let argv = try strings(commandValue, "\(path).command")
            guard let first = argv.first else { throw fail("\(path).command", "must not be empty") }
            guard first.hasPrefix("/") else { throw fail("\(path).command[0]", "must be an absolute path") }
            c.command = argv
        }
        if let gh = try optionalString(m, "gh", path) {
            guard c.builtin == "github" else { throw fail("\(path).gh", "only allowed on the github builtin") }
            guard gh.hasPrefix("/") else { throw fail("\(path).gh", "must be an absolute path") }
            c.gh = gh
        }
        c.map = try optionalString(m, "map", path)
        if let map = c.map, map.isEmpty { throw fail("\(path).map", "must not be empty") }
        if let every = try optionalString(m, "every", path) {
            guard let minutes = parseEvery(every) else { throw fail("\(path).every", "must look like 15m or 1h") }
            guard minutes >= 15 else { throw fail("\(path).every", "must be at least 15m") }
            c.every = every
        }
        if let times = try optionalStrings(m, "at", path) {
            for (i, t) in times.enumerated() { try clock(t, "\(path).at[\(i)]") }
            c.at = times
        }
        if let envValue = m["env"], !envValue.isNull {
            guard case .object(let env) = envValue else { throw fail("\(path).env", "must be an object") }
            for key in env.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                let p = "\(path).env.\(key)"
                let b = Array(key.utf8)
                let upper: (UInt8) -> Bool = { $0 >= 0x41 && $0 <= 0x5A }
                let valid = !b.isEmpty && (upper(b[0]) || b[0] == 0x5F)
                    && b.allSatisfy { upper($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
                guard valid else { throw fail(p, "key must match ^[A-Z_][A-Z0-9_]*$") }
                guard !reservedEnv.contains(key) else {
                    throw fail(p, "reserved; Cadence sets PATH, HOME, LANG and TZ itself")
                }
                c.env[key] = try string(env[key] ?? .null, p)
            }
        }
        return c
    }
}
