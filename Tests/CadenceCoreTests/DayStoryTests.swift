import Testing

@testable import CadenceCore

@Suite struct DayStoryTests {
    /// Thursday 29 Oct 2026, the spec's example day.
    static let thursday = LocalDate("2026-10-29")!
    static let wednesday = LocalDate("2026-10-28")!

    /// A day past the learning period with nothing else going on.
    static func day(_ edit: (inout DayStory.Input) -> Void = { _ in }) -> DayStory.Input {
        var input = DayStory.Input(date: thursday)
        input.countedWorkdays = 20
        input.usualByNow = 6...8
        edit(&input)
        return input
    }

    static func story(_ edit: (inout DayStory.Input) -> Void) -> DayStory { DayStory(day(edit)) }

    static func expect(
        _ story: DayStory, _ state: DayStory.State, _ headline: String, _ sentence: String, _ voice: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(story.state == state, sourceLocation: sourceLocation)
        #expect(story.headline == headline, sourceLocation: sourceLocation)
        #expect(story.sentence == sentence, sourceLocation: sourceLocation)
        #expect(story.voice == voice, sourceLocation: sourceLocation)
    }

    // MARK: every state, worded as section 5.2 shows it

    @Test func gettingStarted() {
        Self.expect(
            Self.story { $0.firstRun = true }, .firstRun, "Hello. I keep time for your work.",
            "Your work log lives on this Mac. A few steps and we are ready.", "Cadence, set up needed")
        Self.expect(
            Self.story { $0.importing = .init(label: "October", done: 12, total: 20) }, .firstSync, "Your history is coming in.",
            "Importing October: 12 of 20 workdays so far, each marked as backfilled. You can use Cadence while this runs.",
            "Importing history")
        Self.expect(
            Self.story {
                $0.countedWorkdays = 6
                $0.usualByNow = nil
                $0.items = 4
            }, .learning, "Still learning your rhythm.",
            "6 workdays logged so far. After 10, you will see your usual range.", "Cadence, 4 items logged")
    }

    @Test func aNormalDay() {
        Self.expect(
            Self.story { $0.carried = 2 }, .morning, "Thursday is wide open.",
            "2 tasks carried from yesterday. Pick what matters and the rest gets logged for you.", "Plan your day")
        Self.expect(
            Self.story { $0.planned = 4 }, .planned, "Your plan is set.",
            "4 tasks for today, and nothing logged yet. Merges, reviews and sessions appear as they happen.", "4 tasks planned")
        Self.expect(
            Self.story {
                $0.planned = 5
                $0.resolved = 3
                $0.done = 2
                $0.items = 8
            }, .inRhythm, "Right in your rhythm.", "8 items logged, about your usual for now. 2 planned tasks are still open.",
            "2 of 5 planned done, 8 items logged")
        Self.expect(
            Self.story {
                $0.planned = 5
                $0.resolved = 3
                $0.items = 14
            }, .moreThanUsual, "More logged than usual.",
            "14 items so far, and usually 6 to 8 by now. That is a count, not a verdict. 2 planned tasks are still open.",
            "14 items logged, more than usual")
        Self.expect(
            Self.story {
                $0.usualByNow = 4...6
                $0.planned = 5
                $0.resolved = 2
                $0.items = 2
                $0.aiSessions = 1
            }, .fewerThanUsual, "Fewer items logged so far.",
            "2 items, and usually 4 to 6 by now. Long-running work does not show here, including 1 Claude Code session.",
            "2 items logged")
        Self.expect(
            Self.story {
                $0.planned = 5
                $0.resolved = 5
                $0.items = 9
            }, .planSettled, "Your plan is settled.", "Everything you planned is done or moved. Wrap up whenever you are ready.",
            "Plan settled")
        Self.expect(
            Self.story {
                $0.planned = 5
                $0.resolved = 3
                $0.items = 9
                $0.wrapUpReminder = "17:30"
            }, .wrapUpDue, "Time to wrap up.",
            "It is past your 17:30 reminder. 2 planned tasks are still open. It takes under a minute.", "Wrap-up due")
        Self.expect(
            Self.story {
                $0.planned = 5
                $0.resolved = 5
                $0.sealedAt = "18:12"
            }, .sealed, "Plan settled, day closed.", "Sealed at 18:12. Everything is accounted for.", "Day sealed")
    }

    @Test func exceptions() {
        Self.expect(
            Self.story {
                $0.sealedAt = "18:12"
                $0.lateAdditions = 1
            }, .editedAfterWrapUp, "Sealed, with one late addition.",
            "One item arrived after your wrap-up. It is marked as late, and your sealed numbers do not change.",
            "Day sealed, one late addition")
        Self.expect(
            Self.story { $0.previous = .init(date: Self.wednesday, graceOpen: true, sealedBefore: 18) }, .yesterdayOpen,
            "Wednesday is still open.", "You can wrap it up today, until 23:59. It will be marked as sealed the next morning.",
            "Wednesday still open")
        Self.expect(
            Self.story { $0.previous = .init(date: Self.wednesday, graceOpen: false, sealedBefore: 18) }, .closedUnsealed,
            "Wednesday closed unsealed.",
            "That is all it means: its entries are kept, and it is marked as not sealed. 18 days were sealed before it, and that record stands.",
            "Wednesday closed unsealed")
        Self.expect(
            Self.story {
                $0.onCall = true
                $0.items = 7
            }, .onCall, "On call today.",
            "Incidents get logged as they happen. 7 items so far, and your plan can wait if it needs to.", "On call")
        Self.expect(
            Self.story { $0.paused = true }, .paused, "Capture is paused.",
            "Presence and collectors are off until you resume. Anything you log by hand still counts.", "Capture paused")
        Self.expect(
            Self.story {
                $0.behind = .init(source: "GitHub", lastSync: "13:40")
                $0.items = 7
            }, .sourceBehind, "GitHub is behind.", "7 items so far. Last synced at 13:40, so this count may be low.",
            "7 items logged, GitHub is behind")
        Self.expect(
            Self.story { $0.wrapUpReminder = "17:30" }, .nothingLogged, "Nothing logged today.",
            "That can be true, or a source may be off. You can seal it as it is, or mark today as not working.",
            "Nothing logged today")
        Self.expect(
            Self.story { $0.storeProblem = true }, .storeProblem, "I cannot read your log.",
            "Your data is still on disk and nothing has been changed. Here is what to try.", "Cadence needs attention")
    }

    @Test func daysOff() {
        Self.expect(Self.story { $0.dayOff = .leave }, .leave, "You are on leave.", "Nothing is expected today.", "On leave")
        Self.expect(Self.story { $0.dayOff = .sick }, .sick, "You are off sick.", "Nothing is expected today. Rest up.", "Off sick")
        Self.expect(Self.story { $0.dayOff = .holiday }, .holiday, "It is a holiday.", "Nothing is expected today.", "Holiday")
        Self.expect(
            Self.story { $0.dayOff = .weekend }, .weekend, "It is the weekend.",
            "Anything you log shows as a small mark, and it never counts toward your workdays.", "Weekend")
    }

    @Test func dayOffFromTheLedger() {
        #expect(DayStory.DayOff(kind: .workday, label: nil) == nil)
        #expect(DayStory.DayOff(kind: .weekend, label: nil) == .weekend)
        #expect(DayStory.DayOff(kind: .holiday, label: "Diwali") == .holiday)
        #expect(DayStory.DayOff(kind: .leavePlanned, label: nil) == .leave)
        #expect(DayStory.DayOff(kind: .leaveUnplanned, label: " Sick ") == .sick)
        #expect(DayStory.DayOff(kind: .leaveUnplanned, label: "sick") == .sick)
        #expect(DayStory.DayOff(kind: .leaveUnplanned, label: "family") == .leave)
    }

    // MARK: which state wins

    @Test func theOrderOfSection5_2() {
        // Each pair: the higher state wins over everything set for the lower one.
        #expect(Self.story { $0.storeProblem = true; $0.paused = true; $0.sealedAt = "18:12" }.state == .storeProblem)
        #expect(Self.story { $0.paused = true; $0.sealedAt = "18:12" }.state == .paused)
        #expect(
            Self.story { $0.sealedAt = "18:12"; $0.previous = .init(date: Self.wednesday, graceOpen: true, sealedBefore: 3) }.state
                == .sealed)
        #expect(
            Self.story { $0.previous = .init(date: Self.wednesday, graceOpen: true, sealedBefore: 3); $0.dayOff = .leave }.state
                == .yesterdayOpen)
        #expect(Self.story { $0.dayOff = .weekend; $0.firstRun = true }.state == .weekend)
        #expect(Self.story { $0.firstRun = true; $0.importing = .init(label: "October", done: 1, total: 20) }.state == .firstRun)
        #expect(Self.story { $0.importing = .init(label: "October", done: 1, total: 20); $0.countedWorkdays = 2 }.state == .firstSync)
        #expect(Self.story { $0.countedWorkdays = 9; $0.behind = .init(source: "GitHub", lastSync: "13:40") }.state == .learning)
        #expect(Self.story { $0.behind = .init(source: "GitHub", lastSync: "13:40"); $0.onCall = true }.state == .sourceBehind)
        #expect(Self.story { $0.onCall = true; $0.wrapUpReminder = "17:30"; $0.items = 3 }.state == .onCall)
        #expect(Self.story { $0.wrapUpReminder = "17:30"; $0.planned = 2; $0.resolved = 2 }.state == .wrapUpDue)
        #expect(Self.story { $0.planned = 2; $0.resolved = 2 }.state == .planSettled)
        #expect(Self.story { $0.planned = 2; $0.items = 0 }.state == .planned)
        #expect(Self.story { $0.items = 7 }.state == .inRhythm)
    }

    @Test func paceIsOnlyAStatementAboutACount() {
        #expect(Self.story { $0.items = 6 }.state == .inRhythm)
        #expect(Self.story { $0.items = 8 }.state == .inRhythm)
        #expect(Self.story { $0.items = 9 }.state == .moreThanUsual)
        #expect(Self.story { $0.items = 5 }.state == .fewerThanUsual)
        // A logged day with no plan never says anything about a plan.
        let story = Self.story { $0.items = 7 }
        #expect(story.sentence == "7 items logged, about your usual for now.")
        #expect(story.voice == "7 items logged")
    }

    // MARK: wording

    @Test func singularsAndEdges() {
        #expect(Self.story { $0.carried = 1 }.sentence.hasPrefix("1 task carried from yesterday."))
        #expect(Self.story { $0.carried = 0 }.sentence == "Pick what matters and the rest gets logged for you.")
        #expect(Self.story { $0.planned = 1 }.sentence.hasPrefix("1 task for today,"))
        #expect(Self.story { $0.planned = 3; $0.resolved = 2; $0.items = 7 }.sentence.hasSuffix("1 planned task is still open."))
        #expect(
            Self.story { $0.usualByNow = 4...6; $0.items = 1 }.sentence
                == "1 item, and usually 4 to 6 by now. Long-running work does not show here.")
        #expect(Self.story { $0.sealedAt = "18:12" }.headline == "Day closed.")
        let late = Self.story { $0.sealedAt = "18:12"; $0.lateAdditions = 3 }
        #expect(late.headline == "Sealed, with 3 late additions.")
        #expect(late.sentence == "3 items arrived after your wrap-up. They are marked as late, and your sealed numbers do not change.")
        #expect(late.voice == "Day sealed, 3 late additions")
        #expect(
            Self.story { $0.previous = .init(date: Self.wednesday, graceOpen: false, sealedBefore: 0) }.sentence
                == "That is all it means: its entries are kept, and it is marked as not sealed.")
        #expect(Self.story { $0.countedWorkdays = 1; $0.usualByNow = nil }.sentence.hasPrefix("1 workday logged so far."))
        #expect(Self.story { $0.countedWorkdays = 0; $0.usualByNow = nil }.sentence.hasPrefix("No workdays logged yet."))
    }

    @Test func aSourceThatNeverSyncedSaysSo() {
        let story = Self.story { $0.behind = .init(source: "GitHub", lastSync: "-"); $0.items = 2 }
        #expect(story.sentence == "2 items so far. It has not synced yet, so this count may be low.")
    }

    @Test func noComparisonWithoutARange() {
        // Past learning but with no range (every counted day was before a gap in the data): no comparison is made.
        let story = Self.story { $0.usualByNow = nil; $0.items = 7 }
        #expect(story.state == .inRhythm)
        #expect(story.sentence == "7 items logged so far.")
    }

    /// Every state over a spread of counts: the copy rules hold, and "behind" only ever describes a source.
    @Test func everySentenceKeepsTheCopyRules() {
        var stories: [DayStory] = []
        for items in [0, 1, 2, 7, 14] {
            for planned in [0, 1, 5] {
                for edit in Self.edits {
                    stories.append(Self.story { input in
                        input.items = items
                        input.planned = planned
                        input.resolved = min(planned, 1)
                        edit(&input)
                    })
                }
            }
        }
        #expect(Set(stories.map(\.state)) == Set(DayStory.State.allCases))
        for story in stories {
            for text in [story.headline, story.sentence, story.voice] {
                #expect(CopyRules.allows(text), "\(story.state): \(text)")
                #expect(!text.lowercased().contains("streak"), "\(story.state): \(text)")
                if story.state != .sourceBehind { #expect(!text.lowercased().contains("behind"), "\(story.state): \(text)") }
            }
        }
    }

    @Test func copyRulesCatchWhatTheyMust() {
        #expect(CopyRules.allows("Right in your rhythm."))
        #expect(!CopyRules.allows("Your productivity is up."))
        #expect(!CopyRules.allows("A score of 9."))
        #expect(!CopyRules.allows("You missed a day."))
        #expect(!CopyRules.allows("You failed to plan."))
        #expect(!CopyRules.allows("9 \u{2013} 10"))
        #expect(!CopyRules.allows("Done \u{2014} sealed"))
        // Whole words only: "scored" in a title is not the banned word, nor is "dismissed".
        #expect(CopyRules.allows("Dismissed 2 entries."))
    }

    static let edits: [@Sendable (inout DayStory.Input) -> Void] = [
        { $0.firstRun = true },
        { $0.importing = .init(label: "October", done: 3, total: 20) },
        { $0.countedWorkdays = 4; $0.usualByNow = nil },
        { $0.carried = 2; $0.items = 0; $0.planned = 0 },
        { $0.items = 0 },
        { _ in },
        { $0.usualByNow = 0...0 },
        { $0.usualByNow = 20...30 },
        { $0.resolved = $0.planned; $0.planned = max($0.planned, 1); $0.resolved = $0.planned },
        { $0.wrapUpReminder = "17:30"; $0.items = max($0.items, 1) },
        { $0.wrapUpReminder = "17:30"; $0.items = 0; $0.planned = 0 },
        { $0.sealedAt = "18:12" },
        { $0.sealedAt = "18:12"; $0.lateAdditions = 2 },
        { $0.previous = .init(date: DayStoryTests.wednesday, graceOpen: true, sealedBefore: 5) },
        { $0.previous = .init(date: DayStoryTests.wednesday, graceOpen: false, sealedBefore: 5) },
        { $0.onCall = true },
        { $0.dayOff = .leave },
        { $0.dayOff = .sick },
        { $0.dayOff = .holiday },
        { $0.dayOff = .weekend },
        { $0.paused = true },
        { $0.behind = .init(source: "GitHub", lastSync: "13:40") },
        { $0.storeProblem = true },
    ]
}
