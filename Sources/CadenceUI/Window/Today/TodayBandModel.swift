// The rhythm band as values (docs/SPEC.md section 5.1): items logged per counted workday against the usual range as it
// stood on each date, and today against usual by now. Days that are not counted workdays are left out, never zeros.
import CadenceCore
import Foundation

public struct TodayBand: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var date: LocalDate
        public var items: Int
        /// The usual day as it stood on that date, from the days before it. Nil while it was still learning.
        public var usual: UsualRange?

        /// Inside the usual range is a filled dot; outside is hollow.
        public var inside: Bool {
            guard let usual else { return true }
            return items >= usual.low && items <= usual.high
        }
    }

    /// Counted workdays before today, oldest first.
    public var history: [Point]
    public var date: LocalDate
    /// Items logged today. Nil when nothing is logged yet, so today shows as a dashed placeholder, not a zero.
    public var today: Int?
    public var usual: UsualRange
    public var byNow: UsualRange?
    /// A source feeding the count is behind: no comparison is drawn.
    public var stale: Bool
    /// "16:48".
    public var clock: String
    /// The weekday on an earlier day, which names the last point instead of "Today". Nil on the live day.
    public var name: String? = nil

    /// The last point's name: "Today", or the earlier day's weekday.
    public var lastName: String { name ?? String(localized: "Today") }

    /// Every value on the chart, today last.
    var values: [Int] { history.map(\.items) + (today.map { [$0] } ?? []) }

    /// The words of the band, for VoiceOver: charts read as a sentence (section 6.7).
    public var voice: String {
        let logged: String
        if let name {
            logged = today.map { String(localized: "\(DayStoryWords.count($0, String(localized: "item"))) logged on \(name).") }
                ?? String(localized: "Nothing logged on \(name).")
        } else {
            logged = today.map { String(localized: "\(DayStoryWords.count($0, String(localized: "item"))) logged today.") }
                ?? String(localized: "Nothing logged yet today.")
        }
        let usual = String(localized: "A usual day is \(usual.low) to \(usual.high)")
        guard let byNow, !stale else { return "\(logged) \(usual)." }
        return String(localized: "\(logged) \(usual), and usually \(byNow.low) to \(byNow.high) by \(clock).")
    }

    /// The line under the band.
    public var legend: String {
        var parts = [String(localized: "Usual day: \(usual.low) to \(usual.high).")]
        if let byNow, !stale { parts.append(String(localized: "Usual by \(clock): \(byNow.low) to \(byNow.high).")) }
        parts.append(String(localized: "Hollow dots were outside the usual."))
        return parts.joined(separator: " ")
    }

    /// The table twin: one row per date, today last.
    public func rows(locale: Locale) -> [[String]] {
        var rows = history.map { point in
            [
                TodayFormat.shortDate(point.date, locale: locale), "\(point.items)",
                point.usual.map { String(localized: "\($0.low) to \($0.high)") } ?? "-",
            ]
        }
        rows.append([lastName, today.map(String.init) ?? "-", String(localized: "\(usual.low) to \(usual.high)")])
        return rows
    }
}

extension TodayInput {
    /// The band, when there is a usual range to draw.
    public var band: TodayBand? {
        guard let rhythm, let usual = rhythm.usual else { return nil }
        let history = rhythm.points.compactMap { point -> TodayBand.Point? in
            guard let items = point.items, point.date < day.date else { return nil }
            return TodayBand.Point(date: point.date, items: items, usual: point.usual)
        }
        guard !history.isEmpty else { return nil }
        return TodayBand(
            history: history, date: day.date, today: rhythm.today > 0 ? rhythm.today : nil, usual: usual,
            // An earlier day is over, so it reads against the usual day, not against this time of day.
            byNow: past == nil ? rhythm.byNow : nil, stale: day.behind != nil, clock: clock(now),
            name: past == nil ? nil : TodayFormat.weekday(day.date))
    }
}

/// What a store failure says: what happened, what is safe and what to do, with one primary action (section 4.6).
public struct FailureCopy: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case tryAgain, copyText, showFolder, runDoctor, updateSteps, quit, restoreBackup, showDamagedFile

        public var title: String {
            switch self {
            case .tryAgain: String(localized: "Try again")
            case .copyText: String(localized: "Copy my text")
            case .showFolder: String(localized: "Show the folder")
            case .runDoctor: String(localized: "Run cadence doctor")
            case .updateSteps: String(localized: "See update steps")
            case .quit: String(localized: "Quit Cadence")
            case .restoreBackup: String(localized: "Restore from backup")
            case .showDamagedFile: String(localized: "Show the damaged file")
            }
        }
    }

    /// A stop is written in `warn`; anything else is a label.
    public enum Tone: Sendable, Equatable { case stop, wait }

    public var kind: StoreFailure.Kind
    /// The failure, as the table names it.
    public var label: String
    public var title: String
    public var body: String
    public var primary: Action
    public var secondary: Action
    public var tone: Tone

    public init(_ kind: StoreFailure.Kind) {
        self.kind = kind
        switch kind {
        case .busy:
            (label, title, body, primary, secondary, tone) = (
                String(localized: "Store busy past the 3 s timeout"), String(localized: "Your log is busy right now."), String(localized: "Your text is kept."), .tryAgain, .copyText,
                .wait
            )
        case .diskFull:
            (label, title, body, primary, secondary, tone) = (
                String(localized: "Disk full"), String(localized: "Your Mac is out of space."), String(localized: "The text is kept until you free some."), .tryAgain, .copyText, .wait
            )
        case .newerSchema:
            (label, title, body, primary, secondary, tone) = (
                String(localized: "Schema newer than the app"), String(localized: "This log was updated by a newer Cadence."),
                String(localized: "The app will not read or change it until you update."), .updateSteps, .quit, .stop
            )
        case .corrupt:
            (label, title, body, primary, secondary, tone) = (
                String(localized: "Corrupt, missing or broken chain"), String(localized: "Your log did not pass its integrity check."),
                String(localized: "Writing stopped; nothing is overwritten."), .restoreBackup, .showDamagedFile, .stop
            )
        case .denied, .missing, .invalid, .other:
            (label, title, body, primary, secondary, tone) = (
                String(localized: "Sandbox denied or unreadable"), String(localized: "Cadence cannot open its log."),
                String(localized: "Nothing has been changed, and it will not fall back to another location."), .showFolder, .runDoctor, .stop
            )
        }
    }
}
