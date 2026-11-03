import CadenceCore
import Foundation

/// The words the Log and the Inbox share (docs/SPEC.md sections 4.6 and 6.6): work kinds, origins, sources, actors,
/// days and times. Times and dates follow the locale; unknown is "-".
public enum EntryWords {
    public static func family(_ family: Family) -> String {
        switch family {
        case .delivery: String(localized: "Delivery")
        case .review: String(localized: "Review")
        case .initiative: String(localized: "Initiative")
        case .ownership: String(localized: "Ownership")
        case .leadership: String(localized: "Leadership")
        case .ai: String(localized: "AI")
        case .presence: String(localized: "Presence and notes")
        }
    }

    /// The origin as its quiet badge says it: the ledger's own word.
    public static func origin(_ origin: Origin) -> String { origin.rawValue }

    /// The origin as a filter chip says it.
    public static func originChip(_ origin: Origin) -> String {
        switch origin {
        case .observed: String(localized: "Observed")
        case .collected: String(localized: "Collected")
        case .agent: String(localized: "Agent")
        case .selfReported: String(localized: "Self")
        }
    }

    /// What the badge means, for its help tag and VoiceOver.
    public static func originMeaning(_ origin: Origin) -> String {
        switch origin {
        case .observed: String(localized: "Observed on this Mac")
        case .collected: String(localized: "Collected by a source you approved")
        case .agent: String(localized: "Proposed by an agent")
        case .selfReported: String(localized: "Logged by you")
        }
    }

    /// A collector or importer name as a person reads it.
    public static func source(_ name: String) -> String {
        switch name {
        case "github": String(localized: "GitHub")
        case "claude-code": String(localized: "Claude Code")
        case "app", "cli": String(localized: "you")
        case "mcp": String(localized: "an agent")
        default:
            name.split(separator: "-").enumerated()
                .map { $0.offset == 0 ? $0.element.prefix(1).uppercased() + $0.element.dropFirst() : String($0.element) }
                .joined(separator: " ")
        }
    }

    /// Who wrote an event, as the subject of a sentence.
    public static func actor(_ actor: Actor) -> String {
        switch actor {
        case .app, .cli: String(localized: "You")
        case .mcp: String(localized: "An agent")
        case .hook: String(localized: "The Claude Code hook")
        case .collector(let name): source(name)
        case .importer(let name): String(localized: "The \(source(name)) import")
        }
    }

    /// The name of a changed field in an `entry.updated` event.
    static func field(_ name: String) -> String {
        switch name {
        case "title": String(localized: "title")
        case "kind", "family": String(localized: "kind")
        case "occurred_at": String(localized: "time")
        case "duration_s": String(localized: "duration")
        case "quantity": String(localized: "count")
        case "ticket": String(localized: "ticket")
        case "links": String(localized: "links")
        case "tags": String(localized: "tags")
        case "attrs": String(localized: "details")
        case "day": String(localized: "day")
        case "export": String(localized: "proof setting")
        case "backfilled": String(localized: "backfill mark")
        case "after_seal": String(localized: "after wrap-up mark")
        default: String(localized: "details")
        }
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ words: [String]) -> String {
        guard let last = words.last else { return "" }
        guard words.count > 1 else { return last }
        return words.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: days and times

    /// A day heading: "Today", or the locale's short date such as "Wed 28 Oct".
    public static func day(_ day: LocalDate, today: LocalDate, locale: Locale) -> String {
        day == today ? String(localized: "Today") : DayFormat(locale: locale).string(day)
    }

    /// The offset an RFC 3339 timestamp was written in, so a time reads as it did on that day.
    static func zone(ofTimestamp text: String) -> TimeZone? {
        if text.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0) }
        let tail = Array(text.utf8.suffix(6))
        guard tail.count == 6, tail[0] == UInt8(ascii: "+") || tail[0] == UInt8(ascii: "-"), tail[3] == UInt8(ascii: ":"),
            let hours = Int(String(decoding: tail[1...2], as: UTF8.self)),
            let minutes = Int(String(decoding: tail[4...5], as: UTF8.self))
        else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (tail[0] == UInt8(ascii: "-") ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }
}

/// The locale's short date for a calendar day, read in UTC so the day never shifts.
struct DayFormat {
    private let formatter: DateFormatter
    private let calendar: Calendar

    init(locale: Locale) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
    }

    func string(_ day: LocalDate) -> String {
        let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date()
        return formatter.string(from: date)
    }
}

/// The locale's clock time, in hours and minutes.
struct ClockFormat {
    private let formatter: DateFormatter

    init(locale: Locale) {
        formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("jmm")
    }

    func string(_ date: Date, in zone: TimeZone) -> String {
        formatter.timeZone = zone
        return formatter.string(from: date)
    }

    /// An entry's time as it was on its day, or "-" when it has none.
    func string(timestamp: String?) -> String {
        guard let timestamp, let date = Timestamp.parse(timestamp), let zone = EntryWords.zone(ofTimestamp: timestamp) else {
            return "-"
        }
        return string(date, in: zone)
    }
}

/// The Log as it reads (docs/SPEC.md section 4.6): days newest first, each a run of one-line rows.
public struct LogContent: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var time: String
        public var family: Family
        public var title: String
        public var afterWrapUp: Bool
        /// Nil when there is none, and in discreet mode.
        public var ticket: String?
        public var origin: Origin
        /// The row as VoiceOver reads it.
        public var spoken: String
    }

    public struct Day: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var rows: [Row]
    }

    public var days: [Day]

    public static let title = String(localized: "Everything, in order.")
    public static let searchPrompt = String(localized: "Search titles, tickets, notes")
    public static let all = String(localized: "All")
    public static let nothingMatches = String(localized: "Nothing matches.")
    public static let nothingMatchesHint = String(localized: "Try a ticket key or clear the filters.")
    public static let clearFilters = String(localized: "Clear filters")
    public static let nothingLogged = String(localized: "Nothing logged yet.")
    public static let nothingLoggedHint = String(localized: "Entries appear here as you log them.")
    public static let afterWrapUp = String(localized: "After wrap-up")

    /// `entries` newest first. In discreet mode titles become "Item 1", "Item 2" within each day and tickets are hidden
    /// (docs/SPEC.md section 6.7).
    public init(entries: [Entry], today: LocalDate, discreet: Bool, locale: Locale = .current) {
        let clock = ClockFormat(locale: locale)
        var days: [Day] = []
        for entry in entries {
            if days.last?.id != entry.day {
                let title = LocalDate(entry.day).map { EntryWords.day($0, today: today, locale: locale) } ?? entry.day
                days.append(Day(id: entry.day, title: title, rows: []))
            }
            let index = days[days.count - 1].rows.count
            days[days.count - 1].rows.append(Self.row(entry, index: index, discreet: discreet, clock: clock))
        }
        self.days = days
    }

    static func row(_ entry: Entry, index: Int, discreet: Bool, clock: ClockFormat) -> Row {
        let title = LogContent.shownTitle(entry.title, index: index, discreet: discreet)
        // A key the title already carries is not shown twice.
        let ticket = discreet ? nil : entry.ticket.map(\.key).flatMap { entry.title.contains($0) ? nil : $0 }
        let time = clock.string(timestamp: entry.occurredAt)
        var spoken = [time == "-" ? String(localized: "No time") : time, EntryWords.family(entry.family), title]
        if entry.afterSeal { spoken.append(afterWrapUp) }
        if let ticket { spoken.append(String(localized: "ticket \(ticket)")) }
        spoken.append(EntryWords.originMeaning(entry.origin))
        return Row(
            id: entry.id, time: time, family: entry.family, title: title, afterWrapUp: entry.afterSeal, ticket: ticket,
            origin: entry.origin, spoken: spoken.joined(separator: ", "))
    }

    /// A title as a list may show it: "Item 1" in discreet mode, as `AppState.title` does.
    static func shownTitle(_ title: String, index: Int, discreet: Bool) -> String {
        discreet ? String(localized: "Item \(index + 1)") : title
    }
}

/// One entry opened (docs/SPEC.md section 4.6): its kind, title, origin and every version the ledger holds.
public struct LogDetail: Sendable, Equatable {
    public struct Version: Sendable, Equatable, Identifiable {
        public var id: Int64
        public var time: String
        /// Who did what, in words: "You logged it", "Collected from GitHub", "You accepted it".
        public var what: String
        /// The title as this version left it.
        public var title: String
    }

    public var id: String
    public var kind: String
    public var title: String
    public var origin: String
    public var versions: [Version]

    public static let historyLabel = String(localized: "History")
    public static let footnote = String(localized: "Edits add a version. Nothing is overwritten.")
    public static let close = String(localized: "Close details")

    /// `events` as `Journal.history` gives them, oldest first; they stay in that order. `index` is the entry's place in
    /// its day, for discreet mode.
    public init(
        entry: Entry, events: [Event], zone: TimeZone, index: Int = 0, discreet: Bool, locale: Locale = .current
    ) {
        id = entry.id
        kind = EntryWords.family(entry.family)
        title = LogContent.shownTitle(entry.title, index: index, discreet: discreet)
        origin = Self.originLine(entry)
        let clock = ClockFormat(locale: locale)
        let days = DayFormat(locale: locale)
        let entryDay = LocalDate(entry.day)
        var current = entry.title
        var versions: [Version] = []
        for event in events {
            guard let payload = try? EventPayload(type: event.type, data: event.data) else { continue }
            let what: String
            switch payload {
            case .entryCreated(let created):
                current = created.title
                what = Self.created(created, by: event.actor)
            case .entryUpdated(let changes):
                if case .string(let new)? = changes.fields["title"]?.new { current = new }
                let fields = Set(changes.fields.keys.map(EntryWords.field)).sorted()
                what = String(localized: "\(EntryWords.actor(event.actor)) changed the \(EntryWords.list(fields))")
            case .entryStatus(let change):
                what = "\(EntryWords.actor(event.actor)) \(Self.verb(change))"
            default:
                continue
            }
            var time = "-"
            if let at = Timestamp.parse(event.at) {
                time = clock.string(at, in: zone)
                if let day = Self.day(of: at, in: zone), day != entryDay { time = "\(days.string(day)), \(time)" }
            }
            versions.append(
                Version(id: event.seq, time: time, what: what, title: LogContent.shownTitle(current, index: index, discreet: discreet)))
        }
        self.versions = versions
    }

    /// "Origin is set once and never changes: collected, GitHub." The source is named only when the entry has one.
    static func originLine(_ entry: Entry) -> String {
        var line = String(localized: "Origin is set once and never changes: \(EntryWords.origin(entry.origin))")
        if let name = entry.source, !name.isEmpty { line += ", \(EntryWords.source(name))" }
        return line + "."
    }

    static func created(_ entry: Entry, by actor: Actor) -> String {
        switch actor {
        case .app, .cli:
            if case .bool(true)? = entry.attrs["dictated"] { return String(localized: "You dictated it") }
            return String(localized: "You logged it")
        case .mcp: return entry.status == .proposed ? String(localized: "Proposed by an agent") : String(localized: "Logged by an agent")
        case .hook: return String(localized: "Observed through the Claude Code hook")
        case .collector(let name): return String(localized: "Collected from \(EntryWords.source(name))")
        case .importer(let name): return String(localized: "Imported from \(EntryWords.source(name))")
        }
    }

    static func verb(_ change: EntryStatusChange) -> String {
        switch (change.from, change.to) {
        case (.dismissed, .accepted): String(localized: "restored it")
        case (_, .accepted): String(localized: "accepted it")
        case (_, .dismissed): String(localized: "dismissed it")
        case (_, .deleted): String(localized: "deleted it")
        case (_, .proposed): String(localized: "proposed it")
        }
    }
}

/// A title being edited in place, in an Inbox row or the Log's detail (docs/SPEC.md section 4.6): the words typed so far
/// and, after a refused save, why. An edit adds a version through `AppState`; the origin and status never change.
public struct TitleEdit: Sendable, Equatable {
    public var entry: String
    public var draft: String
    /// Why the last save was refused, shown under the field. Nil while there is nothing to say.
    public var problem: String?

    public static let edit = "Edit"
    public static let editTitle = "Edit title"
    public static let done = "Done"
    public static let changeKind = "Change kind"
    public static let emptyTitle = "A title needs a few words. Nothing was changed."

    public init(entry: String, draft: String, problem: String? = nil) {
        self.entry = entry
        self.draft = draft
        self.problem = problem
    }

    /// The words to save, trimmed. Nil when there are none.
    var cleaned: String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// "Cadence could not do that. Your text is kept."
    static func refused(_ failure: StoreFailure?) -> String {
        "\(failure?.summary ?? "Cadence could not save that"). Your text is kept."
    }

    /// "Cadence could not do that. The kind is as it was."
    static func refusedKind(_ failure: StoreFailure?) -> String {
        "\(failure?.summary ?? "Cadence could not save that"). The kind is as it was."
    }

    /// Every kind an entry can take, under its work kind, in the work kinds' own order.
    /// Kinds a person can give an entry. Presence spans and AI sessions and usage are measured, never typed.
    static let measured: Set<EntryKind> = [.presenceSpan, .genaiSession, .genaiUsage]

    static let kindsByFamily: [(family: Family, kinds: [EntryKind])] = Family.allCases.compactMap { family in
        let kinds = EntryKind.allCases.filter { $0.defaultFamily == family && !measured.contains($0) }
        return kinds.isEmpty ? nil : (family, kinds)
    }
}

extension LogDetail {
    /// The calendar day `date` falls on in `zone`.
    static func day(of date: Date, in zone: TimeZone) -> LocalDate? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return LocalDate(year: year, month: month, day: day)
    }
}
