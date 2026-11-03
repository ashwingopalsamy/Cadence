import Foundation

/// One stretch of awake time that belongs to a single workday.
public struct PowerLogSpan: Sendable, Equatable {
    public var day: LocalDate
    public var start: Date
    public var end: Date

    public init(day: LocalDate, start: Date, end: Date) {
        self.day = day
        self.start = start
        self.end = end
    }
}

public struct PowerLogResult: Sendable, Equatable {
    /// Awake spans in time order, split at the day boundary, none shorter than the parser's minimum.
    public var spans: [PowerLogSpan]
    /// Lines that start like a dated log line but could not be read. Skipped.
    public var malformed: Int
    /// Wake, sleep and display events that were used.
    public var events: Int
}

/// Per-day summary of spans for the dry-run table.
public struct PowerLogDay: Sendable, Equatable {
    public var day: LocalDate
    /// RFC 3339 in the zone given to `summarize`.
    public var first: String
    public var last: String
    public var spans: Int

    public static func summarize(_ spans: [PowerLogSpan], in zone: TimeZone) -> [PowerLogDay] {
        var byDay: [LocalDate: (first: Date, last: Date, count: Int)] = [:]
        for span in spans {
            if let old = byDay[span.day] {
                byDay[span.day] = (min(old.first, span.start), max(old.last, span.end), old.count + 1)
            } else {
                byDay[span.day] = (span.start, span.end, 1)
            }
        }
        return byDay.keys.sorted().map { day in
            let row = byDay[day]!
            return PowerLogDay(
                day: day, first: Timestamp.local(row.first, in: zone), last: Timestamp.local(row.last, in: zone),
                spans: row.count)
        }
    }
}

/// Reads the text of `pmset -g log` into awake spans (docs/SPEC.md section 8.4).
///
/// A Wake line or "Display is turned on" starts awake time; a Sleep line or "Display is turned off" ends it.
/// DarkWake (maintenance wakes) and every other event type are ignored. Lines carry their own UTC offset, so
/// each one is a real instant; the profile zone is used only to assign workdays.
public struct PowerLogParser: Sendable {
    public let zone: TimeZone
    public let boundary: DayBoundary
    /// Spans shorter than this many seconds are dropped.
    public let minimumSeconds: Int

    public init(zone: TimeZone, boundary: DayBoundary, minimumSeconds: Int = 60) {
        self.zone = zone
        self.boundary = boundary
        self.minimumSeconds = minimumSeconds
    }

    private struct Event {
        var at: Date
        var on: Bool
        var order: Int
    }

    private enum Line {
        case event(Date, on: Bool)
        case ignored
        case malformed
    }

    /// `now` bounds the log: later lines are ignored, and awake time still open at the end is kept only when it
    /// started on today's workday.
    public func parse(_ text: String, now: Date) -> PowerLogResult {
        var events: [Event] = []
        var malformed = 0
        var order = 0
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            switch Self.line(raw) {
            case .event(let at, let on):
                guard at <= now else { continue }
                events.append(Event(at: at, on: on, order: order))
                order += 1
            case .ignored: continue
            case .malformed: malformed += 1
            }
        }
        events.sort { ($0.at, $0.order) < ($1.at, $1.order) }

        var intervals: [(Date, Date)] = []
        var open: Date?
        for event in events {
            if event.on {
                if open == nil { open = event.at }
            } else if let start = open {
                intervals.append((start, event.at))
                open = nil
            }
        }
        if let start = open, boundary.day(of: start, in: zone) == boundary.day(of: now, in: zone) {
            intervals.append((start, now))
        }

        var spans: [PowerLogSpan] = []
        for (start, end) in intervals {
            spans += split(start: start, end: end)
        }
        return PowerLogResult(spans: spans, malformed: malformed, events: events.count)
    }

    /// Cuts an interval at every day boundary it crosses and drops pieces under the minimum.
    private func split(start: Date, end: Date) -> [PowerLogSpan] {
        var out: [PowerLogSpan] = []
        var cursor = start
        while cursor < end {
            let day = boundary.day(of: cursor, in: zone)
            let dayEnd = boundary.interval(of: day, in: zone).end
            let stop = dayEnd > cursor ? min(end, dayEnd) : end
            if Int(stop.timeIntervalSince(cursor)) >= minimumSeconds {
                out.append(PowerLogSpan(day: day, start: cursor, end: stop))
            }
            cursor = stop
        }
        return out
    }

    // MARK: - One line

    /// "YYYY-MM-DD HH:MM:SS +ZZZZ Type<TAB>detail".
    private static func line(_ raw: Substring) -> Line {
        let b = Array(raw.utf8)
        // Only lines that begin like a date count as log lines; headers and blanks are ignored quietly.
        guard b.count >= 5, LocalDate.digits(b[0..<4]) != nil, b[4] == 0x2D else { return .ignored }
        guard b.count >= 26, b[7] == 0x2D, b[10] == 0x20, b[13] == 0x3A, b[16] == 0x3A, b[19] == 0x20,
            b[20] == 0x2B || b[20] == 0x2D,
            let y = LocalDate.digits(b[0..<4]), let mo = LocalDate.digits(b[5..<7]),
            let d = LocalDate.digits(b[8..<10]), let h = LocalDate.digits(b[11..<13]),
            let mi = LocalDate.digits(b[14..<16]), let s = LocalDate.digits(b[17..<19]),
            let oh = LocalDate.digits(b[21..<23]), let om = LocalDate.digits(b[23..<25]),
            h <= 23, mi <= 59, s <= 59, oh <= 23, om <= 59,
            let date = LocalDate(year: y, month: mo, day: d), b[25] == 0x20
        else { return .malformed }
        let offset = (oh * 3600 + om * 60) * (b[20] == 0x2D ? -1 : 1)
        let at = Date(timeIntervalSince1970: Double(date.epochDays * 86_400 + h * 3600 + mi * 60 + s - offset))

        let rest = String(decoding: b[26...], as: UTF8.self)
        let type: String
        let detail: String
        if let tab = rest.firstIndex(of: "\t") {
            type = rest[..<tab].trimmingCharacters(in: .whitespaces)
            detail = String(rest[rest.index(after: tab)...])
        } else {
            type = rest.trimmingCharacters(in: .whitespaces)
            detail = ""
        }
        switch type {
        case "Wake": return .event(at, on: true)
        case "Sleep": return .event(at, on: false)
        case "DarkWake": return .ignored
        default:
            if detail.hasPrefix("Display is turned on") { return .event(at, on: true) }
            if detail.hasPrefix("Display is turned off") { return .event(at, on: false) }
            return .ignored
        }
    }
}
