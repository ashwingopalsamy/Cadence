import Foundation

/// Everything the parser needs besides the line: an injected clock and the ticket rules.
public struct CaptureContext: Sendable {
    public var now: Date
    public var zone: TimeZone
    public var boundary: DayBoundary
    public var classifier: TicketClassifier

    public init(now: Date, zone: TimeZone, boundary: DayBoundary = .standard, classifier: TicketClassifier) {
        self.now = now
        self.zone = zone
        self.boundary = boundary
        self.classifier = classifier
    }
}

/// One recognised piece of the line, for the chips in the capture bar.
public struct CaptureToken: Sendable, Equatable {
    public enum Kind: String, Sendable { case ticket, link, kind, time, day, duration, count, tag }
    public var kind: Kind
    public var text: String
    public var range: Range<String.Index>

    public init(kind: Kind, text: String, range: Range<String.Index>) {
        self.kind = kind
        self.text = text
        self.range = range
    }
}

public struct ParsedCapture: Sendable, Equatable {
    public var title: String
    public var kind: EntryKind
    public var kindMatched: Bool
    public var ticket: Ticket?
    public var links: [Link]
    public var day: LocalDate
    public var occurredAt: Date?
    public var durationS: Int64?
    public var quantity: Int64
    public var tags: [String]
    public var backfilled: Bool
    public var tokens: [CaptureToken]
}

/// The deterministic capture parser (docs/SPEC.md section 4.3). Total: it never traps on any input.
public enum CaptureParser {
    public static func parse(_ line: String, context: CaptureContext) -> ParsedCapture {
        parseLine(line, context: context, baseDay: nil).capture
    }

    /// Splits a dictation transcript into lines and bullets and parses each. A line that is only a day sets the
    /// day for the lines after it.
    public static func parseTranscript(_ text: String, context: CaptureContext) -> [ParsedCapture] {
        splitTranscript(text, context: context).map(\.capture)
    }

    /// One line or bullet of a transcript.
    public struct TranscriptLine: Sendable, Equatable {
        /// The line with its bullet taken off.
        public var text: String
        /// The day the line names itself, or takes from a day-only line above it. Nil when it names none, so the
        /// caller decides what day it is for.
        public var day: LocalDate?
        public var capture: ParsedCapture
    }

    /// The lines of a transcript with the day each one names, in order. Blank lines and day-only lines are not
    /// returned.
    public static func splitTranscript(_ text: String, context: CaptureContext) -> [TranscriptLine] {
        var result: [TranscriptLine] = []
        var baseDay: LocalDate?
        for rawLine in text.components(separatedBy: .newlines) {
            for piece in rawLine.components(separatedBy: "\u{2022}") {
                let line = stripBullet(piece)
                if line.isEmpty { continue }
                let parsed = parseLine(line, context: context, baseDay: baseDay)
                if parsed.isDayOnly {
                    baseDay = parsed.capture.day
                    continue
                }
                let named = baseDay != nil || parsed.capture.tokens.contains { $0.kind == .day }
                result.append(TranscriptLine(text: line, day: named ? parsed.capture.day : nil, capture: parsed.capture))
            }
        }
        return result
    }

    // MARK: Internals

    private static let bulletPattern = Rx(#"^\s*(?:[-*]|\d{1,3}[.)])(?:\s+|$)"#)

    private static func stripBullet(_ piece: String) -> String {
        var s = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = bulletPattern.first(in: s), let r = Range(m.range, in: s) {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    private struct Result {
        var capture: ParsedCapture
        /// True when the only thing on the line is a day token.
        var isDayOnly: Bool
    }

    private struct Tok {
        var kind: CaptureToken.Kind
        var range: NSRange
        /// Removed from the title (time, day, duration and tag tokens).
        var remove: Bool
    }

    private static func parseLine(_ line: String, context: CaptureContext, baseDay: LocalDate?) -> Result {
        let zone = context.zone
        let today = context.boundary.day(of: context.now, in: zone)
        var toks: [Tok] = []
        var protected: [NSRange] = []

        func overlaps(_ a: NSRange, _ b: NSRange) -> Bool { NSIntersectionRange(a, b).length > 0 }
        func clear(_ r: NSRange) -> Bool {
            !toks.contains { overlaps($0.range, r) } && !protected.contains { overlaps($0, r) }
        }
        func add(_ kind: CaptureToken.Kind, _ r: NSRange, remove: Bool = false) {
            toks.append(Tok(kind: kind, range: r, remove: remove))
        }

        // 1. Links. Every http(s) URL is protected from the other rules; only an https URL that the link rule keeps
        // becomes a link, and a URL that becomes a link leaves the title (a repeat of one goes too). The rest stay in it.
        var links: [Link] = []
        var repeats: [NSRange] = []
        for m in Lex.url.all(in: line) {
            let r = trimmedURL(m.range, in: line)
            guard r.length > 0, let sr = Range(r, in: line) else { continue }
            protected.append(r)
            let url = String(line[sr])
            guard url.lowercased().hasPrefix("https://"), url.count > "https://".count,
                LinkRule.isKept(url, httpHosts: [])
            else { continue }
            let link = Link(kind: linkKind(url), url: url)
            if links.contains(link) {
                repeats.append(r)
                continue
            }
            if links.count >= 5 { continue }
            links.append(link)
            add(.link, r, remove: true)
        }

        // 2. Tickets. All are protected; the first one is the entry's ticket.
        var ticket: Ticket?
        for (i, t) in context.classifier.allTickets(in: line).enumerated() {
            let r = NSRange(t.range, in: line)
            let inLink = protected.contains { overlaps($0, r) }
            protected.append(r)
            if i == 0 {
                ticket = Ticket(key: t.key, class: t.selfInitiated ? .selfInitiated : .assigned)
                if !inLink { add(.ticket, r) }
            }
        }

        // 3. Tags.
        var tags: [String] = []
        for m in Lex.tag.all(in: line) {
            guard clear(m.range), let nr = Range(m.range(at: 1), in: line) else { continue }
            let word = String(line[nr]).lowercased()
            // "#412" is a PR or issue number, not a tag.
            guard word.contains(where: { $0.isLetter }) else { continue }
            add(.tag, m.range, remove: true)
            if !tags.contains(word) { tags.append(word) }
        }

        // 4. Time of day (first valid one).
        var clock: (hour: Int, minute: Int)?
        var timeCandidates: [(NSRange, Int, Int)] = []
        for m in Lex.timeAt.all(in: line) {
            if let c = clockValue(m, in: line, needsMarker: true) { timeCandidates.append((m.range, c.0, c.1)) }
        }
        for m in Lex.timeSign.all(in: line) {
            if let c = clockValue(m, in: line, needsMarker: false) { timeCandidates.append((m.range, c.0, c.1)) }
        }
        timeCandidates.sort { $0.0.location < $1.0.location }
        if let first = timeCandidates.first(where: { clear($0.0) }) {
            add(.time, first.0, remove: true)
            clock = (first.1, first.2)
        }

        // 5. Day (first valid one; on a tie the longer match, so "Wed 28 Oct" beats "Wed").
        var explicitDay: LocalDate?
        var dayCandidates: [(NSRange, LocalDate)] = []
        for m in Lex.dayMonth.all(in: line) {
            if let d = namedDate(m, in: line, dayGroup: 1, monthGroup: 2, yearGroup: 3, today: today) {
                dayCandidates.append((m.range, d))
            }
        }
        for m in Lex.monthDay.all(in: line) {
            if let d = namedDate(m, in: line, dayGroup: 2, monthGroup: 1, yearGroup: 3, today: today) {
                dayCandidates.append((m.range, d))
            }
        }
        for m in Lex.iso.all(in: line) {
            if let sr = Range(m.range, in: line), let d = LocalDate(String(line[sr])), d <= today {
                dayCandidates.append((m.range, d))
            }
        }
        for m in Lex.dayWord.all(in: line) {
            guard let sr = Range(m.range(at: 1), in: line) else { continue }
            let word = String(line[sr])
            if word.lowercased() == "yesterday" {
                dayCandidates.append((m.range, today.adding(days: -1)))
            } else if word.lowercased() == "today" {
                dayCandidates.append((m.range, today))
            } else if let wd = weekdayIndex(word, standalone: true) {
                let delta = LocalDate.floorMod(weekdayOrdinal(today) - wd, 7)
                dayCandidates.append((m.range, today.adding(days: delta == 0 ? -7 : -delta)))
            }
        }
        dayCandidates.sort { ($0.0.location, -$0.0.length) < ($1.0.location, -$1.0.length) }
        if let first = dayCandidates.first(where: { clear($0.0) }) {
            add(.day, first.0, remove: true)
            explicitDay = first.1
        }

        // 6. Duration.
        var durationS: Int64?
        var durationCandidates: [(NSRange, Int64)] = []
        for (rx, mode) in [(Lex.durHM, 0), (Lex.durH, 1), (Lex.durM, 2)] {
            for m in rx.all(in: line) {
                if let s = seconds(m, mode: mode, in: line) { durationCandidates.append((m.range, s)) }
            }
        }
        durationCandidates.sort { ($0.0.location, -$0.0.length) < ($1.0.location, -$1.0.length) }
        if let first = durationCandidates.first(where: { clear($0.0) }) {
            add(.duration, first.0, remove: true)
            durationS = first.1
        }

        // 7. Kind lexicon: the first group with a word in the line wins.
        var lexKind: EntryKind?
        for group in Lex.groups {
            var found: (NSRange, EntryKind)?
            for m in group.regex.all(in: line) where clear(m.range) {
                guard let sr = Range(m.range, in: line) else { continue }
                let key = line[sr].lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if let k = group.kinds[key] {
                    found = (m.range, k)
                    break
                }
            }
            if let (r, k) = found {
                add(.kind, r)
                lexKind = k
                break
            }
        }

        // 8. Count: a leading number, or a verb, then a number and a kind noun.
        var quantity: Int64 = 1
        var nounKind: EntryKind?
        for m in Lex.countLead.all(in: line) + Lex.countVerb.all(in: line) {
            let numberRange = m.range(at: 1)
            let nounRange = m.range(at: 2)
            guard let nr = Range(numberRange, in: line), let n = Int64(line[nr]), (1...50).contains(n),
                let wr = Range(nounRange, in: line)
            else { continue }
            let span = NSRange(location: numberRange.location, length: NSMaxRange(nounRange) - numberRange.location)
            guard clear(span) else { continue }
            add(.count, span)
            quantity = n
            nounKind = Lex.nounKind(String(line[wr]))
            break
        }

        let kind = lexKind ?? nounKind ?? .note
        let kindMatched = lexKind != nil || nounKind != nil

        // The day, and the time on it. A clock time before the boundary is after midnight on the calendar, but
        // still belongs to the same workday.
        let day = explicitDay ?? baseDay ?? today
        var occurredAt: Date?
        if let clock {
            let before = clock.hour * 60 + clock.minute < context.boundary.hour * 60 + context.boundary.minute
            occurredAt = Timestamp.resolve(
                before ? day.adding(days: 1) : day, hour: clock.hour, minute: clock.minute, in: zone)
        }

        // Public tokens, in order of appearance.
        toks.sort { $0.range.location < $1.range.location }
        var tokens: [CaptureToken] = []
        var removals: [Range<String.Index>] = []
        for t in toks {
            guard let r = Range(t.range, in: line) else { continue }
            tokens.append(CaptureToken(kind: t.kind, text: String(line[r]), range: r))
            if t.remove { removals.append(r) }
        }
        removals.append(contentsOf: repeats.compactMap { Range($0, in: line) })
        removals.sort { $0.lowerBound < $1.lowerBound }

        // Title: everything except the removed tokens, whitespace collapsed, one trailing period dropped.
        var rest = ""
        var cursor = line.startIndex
        for r in removals where r.lowerBound >= cursor {
            rest += line[cursor..<r.lowerBound]
            rest += " "
            cursor = r.upperBound
        }
        rest += line[cursor...]
        var title = collapse(rest)
        // Where a URL stood, an empty pair of brackets or a colon left hanging is not part of what was said.
        if !links.isEmpty { title = tidyAfterLinks(title) }
        if title.hasSuffix(".") {
            title.removeLast()
            title = title.trimmingCharacters(in: .whitespaces)
        }
        let dayOnly = tokens.count == 1 && tokens[0].kind == .day && !title.contains { $0.isLetter || $0.isNumber }
        // A line that is only a link is titled by the link's name.
        if title.isEmpty, let first = links.first { title = first.titleName }
        if title.isEmpty { title = line.trimmingCharacters(in: .whitespacesAndNewlines) }

        let capture = ParsedCapture(
            title: title, kind: kind, kindMatched: kindMatched, ticket: ticket, links: links, day: day,
            occurredAt: occurredAt, durationS: durationS, quantity: quantity, tags: tags,
            backfilled: day < today, tokens: tokens)
        return Result(capture: capture, isDayOnly: dayOnly)
    }

    // MARK: Helpers

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let emptyBrackets = Rx(#"[(\[<]\s*[)\]>]"#)

    /// The title once its links are out: empty bracket pairs taken away, and no colon, comma, semicolon or hyphen
    /// left at the end. A title with nothing but punctuation left is empty.
    private static func tidyAfterLinks(_ title: String) -> String {
        var text = title
        while let m = emptyBrackets.first(in: text), let r = Range(m.range, in: text) {
            text.replaceSubrange(r, with: " ")
        }
        text = collapse(text)
        let edge: Set<Character> = [":", ",", ";", "-", " "]
        while let last = text.last, edge.contains(last) { text.removeLast() }
        return text.contains { $0.isLetter || $0.isNumber } ? text : ""
    }

    private static func trimmedURL(_ r: NSRange, in line: String) -> NSRange {
        guard let sr = Range(r, in: line) else { return NSRange(location: r.location, length: 0) }
        var end = sr.upperBound
        let junk: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "\"", "'"]
        while end > sr.lowerBound, junk.contains(line[line.index(before: end)]) { end = line.index(before: end) }
        return NSRange(sr.lowerBound..<end, in: line)
    }

    private static func linkKind(_ url: String) -> LinkKind {
        if Lex.prPath.first(in: url) != nil { return .pr }
        if Lex.browsePath.first(in: url) != nil { return .ticket }
        return .other
    }

    private static func weekdayOrdinal(_ d: LocalDate) -> Int {
        Weekday.allCases.firstIndex(of: d.weekday) ?? 0
    }

    /// Monday = 0. A standalone "sat", "sun" or "wed" needs a capital letter because they are also English words.
    private static func weekdayIndex(_ word: String, standalone: Bool) -> Int? {
        let w = word.lowercased()
        if standalone, ["sat", "sun", "wed"].contains(w), word.first?.isUppercase != true { return nil }
        switch w {
        case "mon", "monday": return 0
        case "tue", "tues", "tuesday": return 1
        case "wed", "weds", "wednesday": return 2
        case "thu", "thur", "thurs", "thursday": return 3
        case "fri", "friday": return 4
        case "sat", "saturday": return 5
        case "sun", "sunday": return 6
        default: return nil
        }
    }

    private static func monthNumber(_ word: String) -> Int? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return months.firstIndex(of: String(word.lowercased().prefix(3))).map { $0 + 1 }
    }

    private static func namedDate(
        _ m: NSTextCheckingResult, in line: String, dayGroup: Int, monthGroup: Int, yearGroup: Int, today: LocalDate
    ) -> LocalDate? {
        guard let dr = Range(m.range(at: dayGroup), in: line), let d = Int(line[dr]),
            let mr = Range(m.range(at: monthGroup), in: line), let mo = monthNumber(String(line[mr]))
        else { return nil }
        if let yr = Range(m.range(at: yearGroup), in: line) {
            guard let y = Int(line[yr]), let date = LocalDate(year: y, month: mo, day: d), date <= today else { return nil }
            return date
        }
        if let date = LocalDate(year: today.year, month: mo, day: d), date <= today { return date }
        return LocalDate(year: today.year - 1, month: mo, day: d)
    }

    /// Groups: 1 hour, 2 minute (optional), 3 am/pm (optional).
    private static func clockValue(_ m: NSTextCheckingResult, in line: String, needsMarker: Bool) -> (Int, Int)? {
        guard let hr = Range(m.range(at: 1), in: line), var hour = Int(line[hr]) else { return nil }
        var minute = 0
        let hasMinute = m.range(at: 2).location != NSNotFound
        if hasMinute {
            guard let mr = Range(m.range(at: 2), in: line), let v = Int(line[mr]) else { return nil }
            minute = v
        }
        guard (0...59).contains(minute) else { return nil }
        if m.range(at: 3).location != NSNotFound, let ar = Range(m.range(at: 3), in: line) {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (line[ar].lowercased() == "pm" ? 12 : 0)
        } else {
            if needsMarker && !hasMinute { return nil }
            guard (0...23).contains(hour) else { return nil }
        }
        return (hour, minute)
    }

    private static func seconds(_ m: NSTextCheckingResult, mode: Int, in line: String) -> Int64? {
        func number(_ g: Int) -> Double? {
            guard let r = Range(m.range(at: g), in: line) else { return nil }
            return Double(line[r])
        }
        let total: Double
        switch mode {
        case 0:
            guard let h = number(1), let mi = number(2), mi < 60 else { return nil }
            total = h * 3600 + mi * 60
        case 1:
            guard let h = number(1) else { return nil }
            total = h * 3600
        default:
            guard let mi = number(1) else { return nil }
            total = mi * 60
        }
        guard total >= 60, total <= 86_400 else { return nil }
        return Int64(total.rounded())
    }
}

// MARK: - Lexicon and patterns

private struct Rx: @unchecked Sendable {
    let regex: NSRegularExpression?

    init(_ pattern: String) {
        regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    func all(in s: String) -> [NSTextCheckingResult] {
        regex?.matches(in: s, range: NSRange(s.startIndex..., in: s)) ?? []
    }

    func first(in s: String) -> NSTextCheckingResult? { all(in: s).first }
}

private struct LexiconGroup: Sendable {
    let regex: Rx
    let kinds: [String: EntryKind]

    init(_ entries: [(String, EntryKind)]) {
        var map: [String: EntryKind] = [:]
        for (w, k) in entries { map[w] = k }
        kinds = map
        let alternation = entries.map { $0.0.replacingOccurrences(of: " ", with: #"\s+"#) }.joined(separator: "|")
        regex = Rx("(?<![\(Lex.w)])(?:\(alternation))(?![\(Lex.w)])")
    }
}

private enum Lex {
    /// Word characters, for boundaries.
    static let w = #"\p{L}\p{N}\p{M}_"#

    static let url = Rx(#"https?://\S+"#)
    static let prPath = Rx(#"/pull/\d+"#)
    static let browsePath = Rx(#"/browse/[A-Za-z][A-Za-z0-9]*-\d+"#)
    static let tag = Rx("(?<![\(w)&/#])#([\\p{L}\\p{N}_-]+)")

    static let timeAt = Rx("(?<![\(w)])at\\s+(\\d{1,2})(?::(\\d{2}))?\\s?(am|pm)?(?![\(w):])")
    static let timeSign = Rx("(?<![\(w)@])@(\\d{1,2})(?::(\\d{2}))?\\s?(am|pm)?(?![\(w):])")

    static let weekday =
        "monday|mon|tuesday|tues|tue|wednesday|weds|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat|sunday|sun"
    static let month =
        "january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sept|sep|october|oct|november|nov|december|dec"
    static let dayMonth = Rx(
        "(?<![\(w)/@#-])(?<!\\d\\.)(?:(?:\(weekday))[,.]?\\s+)?(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?(\(month))(?![\(w)])(?:,?\\s+(\\d{4})(?![\(w)]))?"
    )
    static let monthDay = Rx(
        "(?<![\(w)/@#-])(?:(?:\(weekday))[,.]?\\s+)?(\(month))\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?![\(w)])(?:,?\\s+(\\d{4})(?![\(w)]))?"
    )
    static let iso = Rx("(?<![\(w)/@#-])\\d{4}-\\d{2}-\\d{2}(?![\(w)-])")
    static let dayWord = Rx("(?<![\(w)/@#-])(yesterday|today|\(weekday))(?![\(w)'\u{2019}-])")

    static let durPrefix = "(?:(?<![\(w).\\-/])(?:for\\s+)?~?|(?<![\(w)])est~|~)"
    static let durHM = Rx("\(durPrefix)(\\d{1,2})h(\\d{1,2})(?:m|min|mins)?(?![\(w)])")
    static let durH = Rx("\(durPrefix)(\\d{1,3}(?:\\.\\d+)?)\\s?(?:hours|hour|hrs|hr|h)(?![\(w)])")
    static let durM = Rx("\(durPrefix)(\\d{1,4})\\s?(?:minutes|minute|mins|min|m)(?![\(w)])")

    static let nouns = "reviews?|meetings?|incidents?|prs?|sessions?|discussions?"
    static let countLead = Rx("^\\s*(\\d{1,3})\\s+(\(nouns))(?![\(w)])")
    static let countVerb = Rx(
        "(?<![\(w)])(?:reviewed|approved|merged|shipped|released|fixed|implemented|built|refactored|finished|raised|proposed|challenged|led|ran|facilitated|demoed|attended|joined|helped|paired|mentored|unblocked|paged|mitigated|prototyped|automated|wrote|drafted)\\s+(\\d{1,3})\\s+(\(nouns))(?![\(w)])"
    )

    static func nounKind(_ noun: String) -> EntryKind {
        let n = noun.lowercased()
        if n.hasPrefix("review") { return .reviewGiven }
        if n.hasPrefix("meeting") { return .meetingAttended }
        if n.hasPrefix("incident") { return .incidentHandled }
        if n.hasPrefix("pr") { return .prMerged }
        if n.hasPrefix("discussion") { return .discussionRaised }
        return .note
    }

    /// Scanned in this order; the first group with a word in the line wins.
    static let groups: [LexiconGroup] = [
        LexiconGroup([
            ("reviewed", .reviewGiven), ("approved", .reviewGiven), ("code review", .reviewGiven),
            ("pr review", .reviewGiven), ("reviewing", .reviewGiven),
        ]),
        LexiconGroup([("merged", .prMerged), ("shipped", .shipped), ("released", .shipped)]),
        LexiconGroup([("opened a pr", .prOpened), ("pr opened", .prOpened)]),
        LexiconGroup([
            ("fixed", .workDone), ("implemented", .workDone), ("built", .workDone), ("refactored", .workDone),
            ("finished", .workDone),
        ]),
        LexiconGroup([("raised", .discussionRaised), ("proposed", .discussionRaised), ("brought up", .discussionRaised)]),
        LexiconGroup([("challenged", .decisionChallenged), ("pushed back", .decisionChallenged)]),
        LexiconGroup([("led", .meetingLed), ("ran", .meetingLed), ("facilitated", .meetingLed), ("demoed", .meetingLed)]),
        LexiconGroup([
            ("attended", .meetingAttended), ("joined", .meetingAttended), ("sync", .meetingAttended),
            ("1:1", .meetingAttended),
        ]),
        LexiconGroup([("helped", .mentoring), ("paired", .mentoring), ("mentored", .mentoring), ("unblocked", .mentoring)]),
        LexiconGroup([
            ("paged", .incidentHandled), ("incident", .incidentHandled), ("hotfix", .incidentHandled),
            ("mitigated", .incidentHandled),
        ]),
        LexiconGroup([
            ("prototyped", .initiativeStarted), ("kicked off", .initiativeStarted), ("automated", .initiativeStarted),
            ("initiative", .initiativeStarted),
        ]),
        LexiconGroup([("wrote", .docWritten), ("drafted", .docWritten), ("rfc", .docWritten), ("adr", .docWritten)]),
    ]
}
