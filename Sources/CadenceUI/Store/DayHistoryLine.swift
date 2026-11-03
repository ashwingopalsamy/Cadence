import CadenceCore
import Foundation

/// The sentence that says when a day was sealed and reopened (docs/SPEC.md section 3), for the hero's second line and the
/// Log's day headers. The ledger keeps every seal and reopening; this only says them.
public enum DayHistoryLine {
    /// The most seals and reopenings the line names, the latest ones, so it fits the hero.
    public static let shown = 5

    /// "Sealed 13:15, reopened 14:02, sealed again 15:30" once a day has been sealed more than once, and "Reopened at 14:02.
    /// Wrap up again when you're done." while it is open after a reopening. Nil for a day sealed once, or never. Times are
    /// the clock of `zone`, in hours and minutes.
    public static func text(_ history: [DayHistoryItem], zone: TimeZone) -> String? {
        guard let last = history.last else { return nil }
        func time(_ item: DayHistoryItem) -> String { Timestamp.clockTime(item.at, in: zone) }
        if last.kind == .reopened {
            return String(localized: "Reopened at \(time(last)). Wrap up again when you're done.")
        }
        guard history.count > 1 else { return nil }
        var parts: [String] = []
        for (index, item) in history.suffix(shown).enumerated() {
            switch (item.kind, index == 0) {
            case (.sealed, true): parts.append(String(localized: "Sealed \(time(item))"))
            case (.sealed, false): parts.append(String(localized: "sealed again \(time(item))"))
            case (.reopened, true): parts.append(String(localized: "Reopened \(time(item))"))
            case (.reopened, false): parts.append(String(localized: "reopened \(time(item))"))
            }
        }
        return parts.joined(separator: ", ")
    }
}

extension DayContext {
    /// The day was reopened and has not been sealed again: it can be changed, as an unsealed day can.
    var isReopened: Bool { view.day.sealedAt == nil && history.last?.kind == .reopened }
}
