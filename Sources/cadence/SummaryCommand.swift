import ArgumentParser
import CadenceCore
import Foundation

struct SummaryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary",
        abstract: "Metrics for a range: sealed workdays, plan, delivery, review, presence and AI use.",
        discussion: """
            Ranges are read in the profile time zone. week is Monday to today and month is the 1st to today. \
            cycle is the review cycle: from profile.backfillFrom to today, or from the last 1 October when \
            that is not set. A dash, or null in JSON, means there is no data.
            """)

    @OptionGroup var output: OutputOptions
    @Option(help: "week, month, cycle or YYYY-MM-DD..YYYY-MM-DD. Default: week.") var range: String = "week"

    func run() throws {
        try output.run { context in
            let parsed = try SummaryRange.parse(range)
            let summary = try context.openJournal().summary(parsed)
            return Rendered(human: SummaryRendering.human(summary), json: summary.json)
        }
    }
}
