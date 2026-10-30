import Foundation

extension Config {
    /// The config as a JSON tree with every default filled in, so `parse(json) == self`.
    public var json: JSONValue {
        var top: [String: JSONValue] = [:]
        top["cadence"] = .string(Config.format)

        var profileObject: [String: JSONValue] = ["timezone": .string(profile.timezone)]
        if let n = profile.name { profileObject["name"] = .string(n) }
        if let r = profile.role { profileObject["role"] = .string(r) }
        if let b = profile.backfillFrom { profileObject["backfillFrom"] = .string(b.description) }
        top["profile"] = .object(profileObject)

        top["workdays"] = .array(workdays.map { .string($0.rawValue) })
        top["dayBoundary"] = .string(Config.clockText(dayBoundary))
        top["reminders"] = .array(
            reminders.map { r in
                var o: [String: JSONValue] = ["kind": .string(r.kind.rawValue)]
                if let at = r.at { o["at"] = .string(at) }
                if let after = r.after { o["after"] = .string(after) }
                return .object(o)
            })

        var ticketsObject: [String: JSONValue] = [
            "pattern": .string(tickets.pattern),
            "titleWindow": .int(Int64(tickets.titleWindow)),
            "selfInitiated": .string(tickets.selfInitiated),
        ]
        if let l = tickets.linkTemplate { ticketsObject["linkTemplate"] = .string(l) }
        top["tickets"] = .object(ticketsObject)

        if let team {
            var o: [String: JSONValue] = ["hours": .array(team.hours.map { .string($0) })]
            if let z = team.timezone { o["timezone"] = .string(z) }
            top["team"] = .object(o)
        }
        top["sounds"] = .string(sounds.rawValue)
        top["claudeCode"] = .object([
            "injectPlanAtSessionStart": .bool(claudeCode.injectPlanAtSessionStart),
            "projectsDir": .string(claudeCode.projectsDir),
        ])
        top["privacy"] = .object([
            "notificationTitles": .bool(privacy.notificationTitles),
            "exportSpans": .bool(privacy.exportSpans),
            "projectAliases": .bool(privacy.projectAliases),
        ])

        var collectorsObject: [String: JSONValue] = [:]
        for c in collectors {
            var o: [String: JSONValue] = ["enabled": .bool(c.enabled)]
            if let b = c.builtin { o["builtin"] = .string(b) }
            if let argv = c.command { o["command"] = .array(argv.map { .string($0) }) }
            if !c.env.isEmpty { o["env"] = .object(c.env.mapValues { .string($0) }) }
            if let gh = c.gh { o["gh"] = .string(gh) }
            if let m = c.map { o["map"] = .string(m) }
            if let e = c.every { o["every"] = .string(e) }
            if !c.at.isEmpty { o["at"] = .array(c.at.map { .string($0) }) }
            collectorsObject[c.name] = .object(o)
        }
        top["collectors"] = .object(collectorsObject)

        top["hosts"] = .array(hosts.map { .string($0) })
        top["ai"] = .object(["markers": .array(aiMarkers.map { .string($0) })])
        var genaiObject: [String: JSONValue] = ["priority": .array(genai.priority.map { .string($0) })]
        if let p = genai.prices { genaiObject["prices"] = .object(p) }
        top["genai"] = .object(genaiObject)
        top["signals"] = .array(signals.map { .string($0) })
        return .object(top)
    }

    static func clockText(_ b: DayBoundary) -> String {
        String(format: "%02d:%02d", b.hour, b.minute)
    }

    private static func segments(_ path: String) -> [String] {
        path.isEmpty ? [] : path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    private static func notFound(_ path: String) -> CadenceError { .notFound("config key not found: \(path)") }

    /// The JSON at a dotted path such as `tickets.titleWindow` or `reminders.1.at`; "" is the whole config.
    public func value(at path: String) throws(CadenceError) -> JSONValue {
        var current = json
        for segment in Config.segments(path) {
            switch current {
            case .object(let o):
                guard let next = o[segment] else { throw Config.notFound(path) }
                current = next
            case .array(let a):
                guard let i = Int(segment), a.indices.contains(i) else { throw Config.notFound(path) }
                current = a[i]
            default:
                throw Config.notFound(path)
            }
        }
        return current
    }

    /// A copy with `valueText` (JSON) stored at `path`, validated as a whole. A bare word that is not JSON is
    /// taken as a string (`sounds full`); `null` removes an optional key.
    public func setting(_ path: String, to valueText: String) throws(CadenceError) -> Config {
        let segments = Config.segments(path)
        guard !segments.isEmpty else { throw .validation("config key must not be empty") }
        guard segments[0] != "cadence" else { throw .validation("cadence: cannot be changed") }
        let newValue = try Config.parseValueText(valueText)
        let updated = try Config.replacing(json, segments[...], with: newValue, fullPath: path)
        return try Config(validating: updated, fallbackZone: nil)
    }

    private static func parseValueText(_ text: String) throws(CadenceError) -> JSONValue {
        do {
            return try JSONParser.parse(text)
        } catch {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, !"{[\"".contains(first) { return .string(trimmed) }
            throw .validation("value is not valid JSON: \(describe(error))")
        }
    }

    private static func replacing(
        _ node: JSONValue, _ rest: ArraySlice<String>, with newValue: JSONValue, fullPath: String
    ) throws(CadenceError) -> JSONValue {
        guard let head = rest.first else { return newValue }
        let tail = rest.dropFirst()
        switch node {
        case .object(var o):
            if tail.isEmpty {
                if newValue.isNull { o[head] = nil } else { o[head] = newValue }
            } else {
                o[head] = try replacing(o[head] ?? .object([:]), tail, with: newValue, fullPath: fullPath)
            }
            return .object(o)
        case .array(var a):
            guard let i = Int(head), a.indices.contains(i) else { throw notFound(fullPath) }
            a[i] = try replacing(a[i], tail, with: newValue, fullPath: fullPath)
            return .array(a)
        default:
            throw notFound(fullPath)
        }
    }
}
