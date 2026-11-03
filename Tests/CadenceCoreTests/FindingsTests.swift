import Foundation
import Testing

@testable import CadenceCore

/// T4.5: the findings engine against the October ACME demo seed, and its edges.
@Suite struct FindingsTests {
    /// The seeded demo read on Sat 31 Oct at 12:00 in Asia/Kolkata. Fri 30 Oct has no data and its grace window
    /// is still open, so it is a workday that is not counted yet.
    static func seededJournal() throws -> Journal {
        let (_, journal, clock) = try DemoSeedTests.seeded()
        clock.set(Timestamp.parse("2026-10-31T06:30:00Z")!)
        return journal
    }

    static func texts(_ summary: Summary) -> [String] { summary.findings.map(\.text) }

    /// A summary with every figure unknown.
    static func blank(_ from: String = "2026-10-01", _ to: String = "2026-10-31", label: String = "month") -> Summary {
        Summary(
            label: label, from: LocalDate(from)!, to: LocalDate(to)!, zone: DemoSeed.timezone, workdays: 0,
            sealedWorkdays: nil, countedWorkdays: 0, beforeLedger: 0, planDone: nil, planTotal: nil, slipsByReason: nil,
            mergedPRs: nil, assignedPRs: nil, selfInitiatedPRs: nil, reviews: nil, entries: nil, entriesByFamily: nil,
            firstActivity: nil, lastActivity: nil, aiDays: nil, aiCountedDays: 0, aiSessions: nil, outputTokens: nil,
            tokenSources: [:], streak: Streak())
    }

    static func weeks(_ points: [(done: Int, total: Int)]) -> [WeekPlan] {
        let first = LocalDate("2026-09-07")!
        return points.enumerated().map { WeekPlan(monday: first.adding(days: 7 * $0.offset), done: $0.element.done, total: $0.element.total) }
    }

    // MARK: the October seed

    @Test func week44MatchesTheRecapFrames() throws {
        let journal = try Self.seededJournal()
        let week = try journal.summary(.week)
        #expect(week.from == LocalDate("2026-10-26")! && week.to == LocalDate("2026-10-31")!)
        #expect(Self.texts(week) == [
            "You merged 4 PRs, reviewed 12 and raised 3 discussions.",
            "78% of your plan got done. 14 of 18 tasks. 3 slipped: 2 reprioritised and 1 blocked.",
            "Led 2 meetings, challenged 1 decision and mentored twice. On call Tue to Wed, with 1 incident.",
            "19 Claude Code sessions. Across 4 of 4 workdays.",
            "1 of 4 merged PRs was self-started.",
            "Your usual day ran from 09:50 to 17:42, over 4 days.",
            "You reviewed on 4 of 4 workdays this week.",
        ])
        #expect(week.findings.map(\.kind) == [.delivery, .plan, .presence, .ai, .selfInitiated, .dayShape, .reviewCadence])
    }

    @Test func octoberHasNoTrendBecauseTheLastWeekFell() throws {
        let journal = try Self.seededJournal()
        let month = try journal.summary(.month)
        #expect(month.weeklyPlan.map { "\($0.done)/\($0.total)" } == ["3/4", "16/20", "17/19", "11/12", "14/18"])
        #expect(Self.texts(month) == [
            "You merged 14 PRs, reviewed 47 and raised 4 discussions.",
            "84% of your plan got done. 61 of 73 tasks. 9 slipped: 6 reprioritised and 3 blocked.",
            "Led 3 meetings, challenged 1 decision and mentored 3 times. On call 27 to 28 Oct, with 1 incident.",
            "51 Claude Code sessions. Across 17 of 19 workdays.",
            "3 of 14 merged PRs were self-started.",
            "Your usual day ran from 09:53 to 17:49, over 19 days.",
            "You reviewed on 19 of 19 workdays this month.",
        ])
    }

    @Test func firstThreeFullWeeksRise() throws {
        let journal = try Self.seededJournal()
        let range = try journal.summary(from: LocalDate("2026-10-01")!, to: LocalDate("2026-10-23")!)
        let trend = range.findings.first { $0.kind == .planTrend }
        // Week 40 holds 4 counted tasks, under the threshold of 5, so the run starts in week 41.
        #expect(trend?.text == "Plan done rose across 3 weeks: 80%, 89%, 92%.")
        #expect(Self.texts(range).first == "You merged 10 PRs, reviewed 35 and raised 1 discussion.")
        #expect(Self.texts(range).contains("You reviewed on 15 of 15 workdays in this range."))
        #expect(Self.texts(range).contains("Led 1 meeting and mentored once."))
    }

    @Test func jsonCarriesTheFindingsAndTheHumanTextListsThem() throws {
        let journal = try Self.seededJournal()
        let week = try journal.summary(.week)
        let json = week.json.objectValue!
        let findings = json["findings"]!.arrayValue!
        #expect(findings.count == 7)
        #expect(findings[1].objectValue?["kind"] == "plan")
        #expect(findings[1].objectValue?["text"] == "78% of your plan got done. 14 of 18 tasks. 3 slipped: 2 reprioritised and 1 blocked.")
        #expect(findings[1].objectValue?["figures"]?.objectValue?["percent"] == 78)
        #expect(findings[1].objectValue?["figures"]?.objectValue?["slipped_by_reason"]?.objectValue?["blocked"] == 1)
        let human = SummaryRendering.human(week)
        #expect(human.contains("Findings\n- You merged 4 PRs, reviewed 12 and raised 3 discussions.\n- 78%"))
        #expect(!human.contains("Findings: none"))
    }

    // MARK: trends

    @Test func twoPointsAreNeverATrend() {
        #expect(Findings.trend([50, 90]) == nil)
        var s = Self.blank()
        s.weeklyPlan = Self.weeks([(5, 10), (9, 10)])
        #expect(Findings.make(s).isEmpty)
        // Two good weeks after a gap are still two points.
        s.weeklyPlan = Self.weeks([(5, 10), (0, 0), (7, 10), (9, 10)])
        #expect(Findings.make(s).isEmpty)
    }

    @Test func threePointsMakeATrendEitherWay() {
        #expect(Findings.trend([70, 80, 90]) == .up)
        #expect(Findings.trend([90, 85, 70]) == .down)
        #expect(Findings.trend([95, 70, 80, 90]) == .up)  // the trailing run only
        var s = Self.blank()
        s.weeklyPlan = Self.weeks([(9, 10), (17, 20), (7, 10)])
        #expect(Self.texts(s) == ["Plan done fell across 3 weeks: 90%, 85%, 70%."])
        s.weeklyPlan = Self.weeks([(9, 10), (6, 10), (7, 10), (8, 10), (9, 10)])
        #expect(Self.texts(s) == ["Plan done rose across 4 weeks: 60%, 70%, 80%, 90%."])
    }

    @Test func tiesBreakARun() {
        #expect(Findings.trend([80, 80, 90]) == nil)
        #expect(Findings.trend([70, 80, 80]) == nil)
        #expect(Findings.trend([80, 80, 80]) == nil)
    }

    @Test func smallMovesAndThinWeeksAreNoTrend() {
        #expect(Findings.trend([80, 82, 84]) == nil)  // 4 points of change, under 5
        #expect(Findings.trend([80, 83, 85]) == .up)
        var s = Self.blank()
        // The second week has 4 tasks, under the threshold, so it ends the run.
        s.weeklyPlan = Self.weeks([(7, 10), (1, 4), (8, 10), (9, 10)])
        #expect(Findings.make(s).isEmpty)
        s.weeklyPlan = Self.weeks([(7, 10), (3, 5), (8, 10), (9, 10)])
        // 70, 60, 80, 90: the run is 60, 80, 90.
        #expect(Self.texts(s) == ["Plan done rose across 3 weeks: 60%, 80%, 90%."])
    }

    // MARK: unknown is not zero

    @Test func unknownFiguresWriteNothing() {
        #expect(Findings.make(Self.blank()).isEmpty)
        var s = Self.blank()
        s.reviews = 5
        #expect(Self.texts(s) == ["You reviewed 5."])
        s.countedWorkdays = 3
        #expect(Self.texts(s) == ["You reviewed 5."])  // review days unknown: no cadence
        s.reviewDays = 2
        #expect(Self.texts(s) == ["You reviewed 5.", "You reviewed on 2 of 3 workdays this month."])
    }

    @Test func knownZerosAreStated() {
        var s = Self.blank("2026-10-26", "2026-10-30", label: "week")
        s.mergedPRs = 0
        s.selfInitiatedPRs = 0
        s.reviews = 0
        s.kindCounts = [:]
        s.planDone = 3
        s.planTotal = 3
        s.slipsByReason = [:]
        s.aiSessions = 0
        #expect(Self.texts(s) == [
            "You merged 0 PRs, reviewed 0 and raised 0 discussions.",
            "100% of your plan got done. 3 of 3 tasks. None slipped.",
            "Nothing beyond the plan was logged.",
            "0 Claude Code sessions.",
        ])
    }

    @Test func slipReasonTiesSortByName() {
        var s = Self.blank()
        s.planDone = 1
        s.planTotal = 4
        s.slipsByReason = ["reprioritised": 1, "blocked": 1, "unspecified": 1]
        #expect(Self.texts(s) == ["25% of your plan got done. 1 of 4 tasks. 3 slipped: 1 blocked, 1 reprioritised and 1 with no reason."])
    }

    @Test func aiMergesWithoutAMarkerAreNamed() {
        var s = Self.blank()
        s.assistedMerges = AssistedMerges(share: Share(2, of: 3), unrecorded: 1)
        #expect(Self.texts(s) == ["2 of your 3 merged PRs with a recorded marker were AI-assisted."])
        s.assistedMerges = AssistedMerges(share: Share(1, of: 1), unrecorded: 0)
        #expect(Self.texts(s) == ["1 of your 1 merged PR was AI-assisted."])
    }

    @Test func onCallSpans() {
        let d = { (text: String) in LocalDate(text)! }
        #expect(Findings.onCallSpan([d("2026-10-27")], weekNames: true) == "Tue")
        #expect(Findings.onCallSpan([d("2026-10-28"), d("2026-10-27")], weekNames: true) == "Tue to Wed")
        #expect(Findings.onCallSpan([d("2026-10-30"), d("2026-10-31"), d("2026-11-01")], weekNames: false) == "30 Oct to 1 Nov")
        #expect(Findings.onCallSpan([d("2026-10-27"), d("2026-10-29")], weekNames: false) == "on 2 days")
        var s = Self.blank()
        s.kindCounts = ["incident.handled": 2]
        #expect(Self.texts(s) == ["You raised 0 discussions.", "Handled 2 incidents."])
    }

    // MARK: audit follow-ups

    @Test func freeTextSlipReasonsNeverReachTheSentence() {
        var s = Self.blank()
        s.planDone = 2
        s.planTotal = 8
        s.slipsByReason = [
            "reprioritised": 2, "missed the cut": 1, "waiting on infra \u{2013} vendor": 1, "Blocked": 1, "too_big": 1,
            "waiting_on_someone": 1,
        ]
        #expect(Self.texts(s) == [
            "25% of your plan got done. 2 of 8 tasks. 7 slipped: 3 for another reason, 2 reprioritised, 1 too big and 1 waiting on someone."
        ])
        #expect(s.findings.first?.figures["slipped_by_reason"] == ["other": 3, "reprioritised": 2, "too_big": 1, "waiting_on_someone": 1])
    }

    @Test func theLintKeepsEveryCopyRule() {
        for text in ["Your productivity rose.", "A score of 9.", "You missed 2 days.", "You failed to plan.", "9 \u{2013} 10"] {
            #expect(!Findings.lint(text), "\(text)")
        }
        #expect(Findings.lint("Dismissed 2 entries."))
    }

    @Test func nothingBeyondThePlanOnlyWhenItIsTrue() {
        var s = Self.blank()
        s.kindCounts = ["discussion.raised": 3, "initiative.started": 2, "doc.written": 1]
        #expect(!Self.texts(s).contains { $0.contains("beyond the plan") })
        #expect(s.findings.map(\.kind) == [.delivery])
        s.kindCounts = ["meeting.attended": 4]
        #expect(Self.texts(s).contains("Nothing beyond the plan was logged."))
    }

    @Test func presenceStatesOnlyWhatItSays() {
        var s = Self.blank("2026-10-26", "2026-10-30", label: "week")
        s.kindCounts = ["meeting.led": 1, "decision.challenged": 2, "mentoring": 3]
        let presence = s.findings.first { $0.kind == .presence }
        #expect(presence?.text == "Led 1 meeting, challenged 2 decisions and mentored 3 times.")
        #expect(presence?.figures == ["meetings_led": 1, "decisions_challenged": 2, "mentoring": 3])
        s.kindCounts = [:]
        s.onCallDays = [LocalDate("2026-10-27")!]
        #expect(s.findings.first { $0.kind == .presence }?.text == "On call Tue.")
        s.onCallDays = [LocalDate("2026-10-27")!, LocalDate("2026-10-29")!]
        s.kindCounts = ["incident.handled": 1]
        #expect(s.findings.first { $0.kind == .presence }?.text == "On call on 2 days, with 1 incident.")
    }

    @Test func eachClauseIsLeftOutWhenUnknown() {
        var s = Self.blank()
        s.mergedPRs = 1
        #expect(Self.texts(s) == ["You merged 1 PR."])  // reviews and kinds unknown; self-started unknown
        s.selfInitiatedPRs = 0
        #expect(Self.texts(s) == ["You merged 1 PR.", "0 of 1 merged PR were self-started."])
        s = Self.blank()
        s.mergedPRs = 0
        s.selfInitiatedPRs = 0
        #expect(Self.texts(s) == ["You merged 0 PRs."])  // no share of zero merges
        s = Self.blank()
        s.planDone = 1
        s.planTotal = 1
        #expect(Self.texts(s) == ["100% of your plan got done. 1 of 1 task."])  // slips unknown: no slip clause
        #expect(s.findings.first?.figures["slipped"] == nil)
        s.planTotal = 0
        s.planDone = 0
        #expect(Self.texts(s).isEmpty)
        s = Self.blank()
        s.aiDays = 3
        s.aiCountedDays = 4
        #expect(Self.texts(s) == ["Claude Code on 3 of 4 workdays."])
        s.aiCountedDays = 0
        #expect(Self.texts(s).isEmpty)
    }

    @Test func dayShapeBranches() {
        var s = Self.blank()
        s.firstActivity = ClockSpread(median: "09:40", earliest: "09:00", latest: "10:30", days: 1)
        #expect(Self.texts(s) == ["Your usual start was 09:40, over 1 day."])
        s.lastActivity = ClockSpread(median: "17:10", earliest: "16:00", latest: "18:00", days: 2)
        #expect(Self.texts(s) == ["Your usual start was 09:40, over 1 day. Your usual end was 17:10, over 2 days."])
        s.firstActivity = nil
        #expect(Self.texts(s) == ["Your usual end was 17:10, over 2 days."])
    }

    @Test func onCallSpansInsideAMonthAndAcrossAYear() {
        let d = { (text: String) in LocalDate(text)! }
        #expect(Findings.onCallSpan([d("2026-10-25"), d("2026-10-26")], weekNames: false) == "25 to 26 Oct")
        #expect(Findings.onCallSpan([d("2026-12-31"), d("2027-01-01")], weekNames: false) == "31 Dec to 1 Jan")
    }

    @Test func isoWeeks() {
        #expect(Findings.isoWeek(LocalDate("2026-10-26")!) == 44)
        #expect(Findings.isoWeek(LocalDate("2026-01-01")!) == 1)
        #expect(Findings.isoWeek(LocalDate("2027-01-01")!) == 53)  // Fri 1 Jan 2027 belongs to 2026's week 53
    }

    // MARK: copy rules

    @Test func noFindingSaysBestSinceOrUsesADash() throws {
        #expect(!Findings.lint("Your best since last week"))
        #expect(!Findings.lint("Best Since August"))
        #expect(!Findings.lint("26\u{2013}30 Oct"))
        #expect(!Findings.lint("done \u{2014} mostly"))
        #expect(Findings.lint("26 to 30 Oct · 5 workdays"))

        let journal = try Self.seededJournal()
        var all: [Finding] = []
        for range in [SummaryRange.week, .month, .cycle, .custom(LocalDate("2026-10-01")!, LocalDate("2026-10-23")!)] {
            all += try journal.summary(range).findings
        }
        for day in LocalDate.range(LocalDate("2026-10-01")!, through: LocalDate("2026-10-31")!) {
            all += try journal.summary(from: day, to: day).findings
        }
        #expect(!all.isEmpty)
        for finding in all {
            #expect(Findings.lint(finding.text), "\(finding.text)")
            #expect(finding.text.first?.isUppercase == true || finding.text.first?.isNumber == true, "\(finding.text)")
            #expect(!finding.text.contains("since"), "\(finding.text)")
        }
    }
}
