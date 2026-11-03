// The Proof section's words (docs/SPEC.md sections 6.6 and 12.4): sentence case, finding first, no dashes, and
// unknown is "-", never 0. Dates follow the locale the view runs in.
import CadenceCore
import Foundation

enum ProofCopy {
    static let kicker = String(localized: "Proof")
    static let checkFile = String(localized: "Check a file")
    static let export = String(localized: "Export and check")
    static let exporting = String(localized: "Exporting and checking")
    static let checking = String(localized: "Checking")
    static let exportAgain = String(localized: "Export again")
    static let doNotShare = String(localized: "Do not share this file.")
    /// Section 12.4 in one line. It stays on the card in every state.
    static let limits = String(localized: "Shows this log was not changed after sealing. It does not show the work happened.")

    static let coverage = String(localized: "Coverage")
    static let covers = String(localized: "This file covers")
    static let sealedUnit = String(localized: "sealed workdays")
    static let range = String(localized: "Range")
    static let included = String(localized: "What is included")

    static let managerSees = String(localized: "What your manager sees")
    static let planDone = String(localized: "Planned done on counted days")

    static let codesKicker = String(localized: "Codes you copied")
    static let notCopied = String(localized: "Not copied, no outside date")

    static let leavesKicker = String(localized: "What leaves this Mac")
    static let noNetwork = String(localized: "The app itself makes no network calls.")
    static let sentNowhere = String(localized: "Your log is sent nowhere unless you hand over this file.")
    static let openVerifier = String(localized: "Anyone can check the file with the open verifier.")
    static let seeSources = String(localized: "See approved sources")

    static let from = String(localized: "From")
    static let to = String(localized: "To")

    /// "Your October, ready to hand over."
    static func title(_ preset: ProofPreset, range: ProofRange?, locale: Locale) -> String {
        let what: String
        switch preset {
        case .week: what = String(localized: "Your week")
        case .month: what = range.map { String(localized: "Your ") + format($0.from, "MMMM", locale) } ?? String(localized: "Your month")
        case .cycle: what = String(localized: "Your cycle")
        case .custom: what = range.map { span($0, locale: locale) } ?? String(localized: "Your range")
        }
        return what + String(localized: ", ready to hand over.")
    }

    /// "1 to 29 Oct", or "28 Sep to 4 Oct". The year shows only when the range crosses one.
    static func span(_ range: ProofRange, locale: Locale) -> String {
        let template = range.from.year == range.to.year ? "dMMM" : "dMMMyyyy"
        let last = format(range.to, template, locale)
        if range.from == range.to { return last }
        if range.from.year == range.to.year, range.from.month == range.to.month, last.hasPrefix(String(range.to.day)) {
            return String(localized: "\(range.from.day) to \(last)")
        }
        return String(localized: "\(format(range.from, template, locale)) to \(last)")
    }

    /// "1 to 29 Oct. 412 events."
    static func coverageLine(_ snapshot: ProofSnapshot, locale: Locale) -> String {
        "\(span(snapshot.range, locale: locale)). \(count(snapshot.eventsInRange, String(localized: "event"), String(localized: "events")))."
    }

    /// "Sealed on 19 of 19 workdays. Done is self-marked."
    static func sealedLine(_ snapshot: ProofSnapshot) -> String {
        guard let sealed = snapshot.sealedWorkdays, let of = snapshot.countedWorkdays else { return String(localized: "Sealed workdays: -. Done is self-marked.") }
        return String(localized: "Sealed on \(sealed) of \(of) \(of == 1 ? String(localized: "workday") : String(localized: "workdays")). Done is self-marked.")
    }

    /// The plan-done share as a whole percent, or nil when nothing was planned on a counted day.
    static func percent(_ done: Int?, of planned: Int?) -> Int? {
        guard let done, let planned, planned > 0 else { return nil }
        return Int((Double(done) * 100 / Double(planned)).rounded())
    }

    /// "15 of 19 days have a code you copied into a stand-up. Those can be checked against that message."
    static func codesLine(_ snapshot: ProofSnapshot) -> String {
        if snapshot.sealedDays == 0 { return String(localized: "No day in this range is sealed yet, so there is no code to check.") }
        let days = snapshot.sealedDays == 1 ? String(localized: "day has") : String(localized: "days have")
        return String(localized: "\(snapshot.codesCopied) of \(snapshot.sealedDays) \(days) a code you copied into a stand-up. Those can be checked against that message.")
    }

    /// "Only sources you approved do: github." Collectors are the only code that reaches out (section 13).
    static func sourcesLine(_ sources: [String]) -> String {
        sources.isEmpty ? String(localized: "No sources are turned on, so nothing else does either.") : String(localized: "Only sources you approved do: \(sources.joined(separator: ", ")).")
    }

    /// One row of "What is included": what leaves, and how much of it.
    struct Inclusion: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// Core's rules for the file, in the order the prototype lists them: titles and ticket keys, private notes,
    /// AI sessions. Each line names a policy the exporter applies; none of them is a switch.
    static func inclusion(_ i: ProofInclusion) -> [Inclusion] {
        [
            Inclusion(label: String(localized: "Task and entry titles, ticket keys and links"), value: count(i.titled, String(localized: "item"), String(localized: "items"))),
            Inclusion(label: String(localized: "Notes and digest entries, title kept back"), value: count(i.digest, String(localized: "item"), String(localized: "items"))),
            Inclusion(label: String(localized: "Entries you excluded, hashes only"), value: count(i.excluded, String(localized: "item"), String(localized: "items"))),
            Inclusion(label: String(localized: "Private notes and reasons"), value: String(localized: "Hashes only")),
            Inclusion(label: String(localized: "AI sessions and usage"), value: String(localized: "Included")),
        ]
    }

    /// "Exported and checked." or "Checked cadence.json."
    static func outcomeHead(_ o: ProofOutcome) -> String {
        if !o.passed { return o.failure ?? String(localized: "This file did not pass its check.") }
        return o.action == .exported ? String(localized: "Exported and checked.") : String(localized: "Checked \(o.fileName).")
    }

    /// The line under the head.
    static func outcomeBody(_ o: ProofOutcome) -> String {
        if o.passed {
            let codes: String
            switch o.codes {
            case 0: codes = String(localized: "no code in it can be checked against a stand-up")
            case 1: codes = String(localized: "1 code can be checked against your stand-ups")
            default: codes = String(localized: "\(o.codes) codes can be checked against your stand-ups")
            }
            let place = o.action == .exported ? String(localized: "\(o.fileName), in \(o.folderName ?? String(localized: "the folder you chose")). ") : ""
            return String(localized: "\(place)Chain intact, and \(codes).")
        }
        switch o.ledger {
        case .verified(let events)?:
            return String(localized: "Cadence checked your ledger again, and all \(events) events verify, so the fault is in this file.")
        case .failed(let problem)?:
            return String(localized: "Cadence checked your ledger again and it did not pass either: \(problem) Run cadence doctor before you export.")
        case nil:
            return o.action == .checked
                ? String(localized: "\(o.fileName) did not pass the checks the open verifier runs.")
                : String(localized: "Nothing you can share was written.")
        }
    }

    /// "Wed 28 Oct"
    static func day(_ date: LocalDate, locale: Locale) -> String { format(date, "EEEdMMM", locale) }

    static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    static func format(_ date: LocalDate, _ template: String, _ locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let instant = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: instant)
    }
}
