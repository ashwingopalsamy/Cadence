import CadenceCore
import Foundation

/// The Inbox as it reads (docs/SPEC.md section 4.6): entries proposed by agents, dictation and backfill, each with its
/// work colour, title, day, why it is here and its origin. Proposals count for nothing until accepted.
public struct InboxContent: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var family: Family
        public var title: String
        /// The day and, when known, the time: "Today, 15:40", "Mon 5 Oct".
        public var when: String
        /// Why it is here: "Proposed by an agent", "From your dictation", "From the October backfill".
        public var why: String
        public var origin: Origin
        /// The row as VoiceOver reads it.
        public var spoken: String

        /// The line under the title.
        public var line: String { "\(when). \(why)." }
    }

    public var rows: [Row]

    public static let label = String(localized: "Inbox")
    public static let acceptAll = String(localized: "Accept all")
    public static let accept = String(localized: "Accept")
    public static let dismiss = String(localized: "Dismiss")
    public static let footnote =
        String(localized: "Proposed entries count for nothing until you accept them. Their origin never changes, even after you edit them.")
    public static let allClear = String(localized: "All clear.")
    public static let emptyTitle = String(localized: "Nothing to review.")
    public static let emptyLine = String(localized: "Entries from agents, dictation and backfill wait here for your yes.")

    /// `entries` in the order shown. In discreet mode titles become "Item 1", "Item 2" (docs/SPEC.md section 6.7).
    public init(entries: [Entry], today: LocalDate, discreet: Bool, locale: Locale = .current) {
        let days = DayFormat(locale: locale)
        let clock = ClockFormat(locale: locale)
        let months = DateFormatter()
        months.locale = locale
        months.timeZone = TimeZone(secondsFromGMT: 0)
        months.setLocalizedDateFormatFromTemplate("MMMM")
        rows = entries.enumerated().map { index, entry in
            let title = LogContent.shownTitle(entry.title, index: index, discreet: discreet)
            var when = LocalDate(entry.day).map { $0 == today ? String(localized: "Today") : days.string($0) } ?? entry.day
            let time = clock.string(timestamp: entry.occurredAt)
            if time != "-" { when += ", \(time)" }
            let why = Self.why(entry, month: { day in
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date()
                return months.string(from: date)
            })
            return Row(
                id: entry.id, family: entry.family, title: title, when: when, why: why, origin: entry.origin,
                spoken: "\(title), \(EntryWords.family(entry.family)), \(when). \(why). \(EntryWords.originMeaning(entry.origin))")
        }
    }

    /// "1 entry waiting for you.", "3 entries waiting for you.", or "All clear." when there is none.
    public var headline: String {
        switch rows.count {
        case 0: Self.allClear
        case 1: String(localized: "1 entry waiting for you.")
        default: String(localized: "\(rows.count) entries waiting for you.")
        }
    }

    /// Why a proposal is here: dictation first, then an agent, then backfill, then its origin.
    static func why(_ entry: Entry, month: (LocalDate) -> String) -> String {
        if case .bool(true)? = entry.attrs["dictated"] { return String(localized: "From your dictation") }
        if entry.origin == .agent {
            if let name = entry.source, !name.isEmpty { return String(localized: "Proposed by \(EntryWords.source(name))") }
            return String(localized: "Proposed by an agent")
        }
        if entry.backfilled, let day = LocalDate(entry.day) { return String(localized: "From the \(month(day)) backfill") }
        switch entry.origin {
        case .collected: return String(localized: "Collected from \(entry.source.map(EntryWords.source) ?? String(localized: "a source"))")
        case .observed: return String(localized: "Observed on this Mac")
        case .agent, .selfReported: return String(localized: "Saved for your review")
        }
    }
}
