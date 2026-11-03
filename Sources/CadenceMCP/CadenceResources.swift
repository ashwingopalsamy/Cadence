import CadenceCore
import Foundation

/// Resources a client can attach to a conversation (docs/SPEC.md section 9.2). Both are plain text, read-only,
/// and cut under the same 20,000 characters as a tool result.
extension CadenceMCP {
    public static let dayResourceTemplate = "cadence://day/{date}"
    public static let weekResourceURI = "cadence://week/current"
    static let dayResourcePrefix = "cadence://day/"

    public static func resources(journal makeJournal: @escaping JournalProvider) -> [MCPResource] {
        [
            MCPResource(
                uri: weekResourceURI, name: "This week",
                description: "The week so far, Monday to today: the summary numbers and each day's plan and entries.",
                mimeType: "text/plain",
                read: { uri throws(CadenceError) in
                    guard uri == weekResourceURI else { return nil }
                    do throws(CadenceError) {
                        return try weekText(makeJournal())
                    } catch {
                        throw ToolText.forAgent(error)
                    }
                }),
            MCPResource(
                uri: dayResourceTemplate, name: "A day",
                description: "One day's plan, entries, presence and ring. Use cadence://day/YYYY-MM-DD.",
                mimeType: "text/plain",
                read: { uri throws(CadenceError) in
                    guard uri.hasPrefix(dayResourcePrefix) else { return nil }
                    let text = String(uri.dropFirst(dayResourcePrefix.count))
                    guard let day = LocalDate(text) else {
                        throw .validation("\(EnvelopeText.printable(uri)) is not a day; use cadence://day/YYYY-MM-DD")
                    }
                    do throws(CadenceError) {
                        return try dayText(makeJournal().dayView(day))
                    } catch {
                        throw ToolText.forAgent(error)
                    }
                }),
        ]
    }

    /// The day as the CLI shows it, then its ring.
    static func dayText(_ view: DayView) -> String {
        cut(DayRendering.human(view) + "\n\n" + DayRing(view).text)
    }

    /// The summary for the week so far, then each day from Monday to today.
    static func weekText(_ journal: Journal) throws(CadenceError) -> String {
        let range = SummaryRange.week.resolve(today: journal.today(), cycleStart: nil)
        var text = SummaryRendering.human(try journal.summary(from: range.from, to: range.to, label: "week"))
        for day in LocalDate.range(range.from, through: range.to) {
            let view = try journal.dayView(day)
            let section = "\n\n---\n\n" + DayRendering.human(view) + "\n" + DayRing(view).text
            if text.count + section.count > ToolText.budget {
                text += "\n\n---\n\nCut at \(MCPServer.maxResultCharacters) characters before \(day). Read cadence://day/YYYY-MM-DD for a single day."
                break
            }
            text += section
        }
        return text
    }

    private static func cut(_ text: String) -> String {
        // The budget leaves room for the JSON around the text and its escapes, so the server never cuts it again.
        guard text.count > ToolText.budget else { return text }
        return String(text.prefix(ToolText.budget - 120))
            + "\nCut at \(MCPServer.maxResultCharacters) characters; use query for this date to page through the entries."
    }
}
