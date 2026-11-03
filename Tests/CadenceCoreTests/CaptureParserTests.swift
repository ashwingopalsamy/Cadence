import Foundation
import Testing

@testable import CadenceCore

@Suite struct CaptureParserTests {
    // Thursday 2026-10-29 15:42 in Asia/Kolkata.
    static let zone = TimeZone(identifier: "Asia/Kolkata") ?? .gmt

    func context() throws -> CaptureContext {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-29T15:42:00+05:30"))
        return CaptureContext(now: now, zone: Self.zone, classifier: try TicketClassifier(rules: .standard))
    }

    func parse(_ line: String) throws -> ParsedCapture {
        CaptureParser.parse(line, context: try context())
    }

    func date(_ s: String) throws -> LocalDate { try #require(LocalDate(s)) }

    func clock(_ p: ParsedCapture) -> String? {
        p.occurredAt.map { Timestamp.clockTime($0, in: Self.zone) }
    }

    // MARK: Spec examples

    struct Example: Sendable, CustomTestStringConvertible {
        let line: String
        let kind: EntryKind
        let matched: Bool
        let ticket: String?
        let ticketClass: TicketClass?
        var testDescription: String { line }
    }

    static let examples: [Example] = [
        Example(line: "raised retry storms in arch sync", kind: .discussionRaised, matched: true, ticket: nil, ticketClass: nil),
        Example(line: "Raised retry storms risk in arch sync", kind: .discussionRaised, matched: true, ticket: nil, ticketClass: nil),
        Example(
            line: "Fixed flaky ledger test with deterministic clock ACME-482913", kind: .workDone, matched: true,
            ticket: "ACME-482913", ticketClass: .assigned),
        Example(line: "Reviewed settlement batching RFC", kind: .reviewGiven, matched: true, ticket: nil, ticketClass: nil),
        Example(line: "Paired on the flaky ledger test", kind: .mentoring, matched: true, ticket: nil, ticketClass: nil),
        Example(line: "Draft idempotency ADR", kind: .docWritten, matched: true, ticket: nil, ticketClass: nil),
        Example(line: "Prototype webhook replay tool ACME-000000", kind: .note, matched: false, ticket: "ACME-000000", ticketClass: .selfInitiated),
        Example(
            line: "Prototyped webhook replay tool ACME-000000", kind: .initiativeStarted, matched: true, ticket: "ACME-000000",
            ticketClass: .selfInitiated),
        Example(line: "Pair on flaky ledger test est~1h #quality", kind: .note, matched: false, ticket: nil, ticketClass: nil),
        Example(
            line: "Shipped retry budget for capture path (ACME-482913), PR #412 merged", kind: .shipped, matched: true,
            ticket: "ACME-482913", ticketClass: .assigned),
    ]

    @Test(arguments: examples)
    func specExamples(_ e: Example) throws {
        let p = try parse(e.line)
        var expected = e.kind
        var matched = e.matched
        if e.line.hasPrefix("Draft idempotency") {
            // "Draft" is not in the lexicon, but "ADR" is, so the kind is doc.written.
            expected = .docWritten
            matched = true
        }
        #expect(p.kind == expected)
        #expect(p.kindMatched == matched)
        #expect(p.ticket?.key == e.ticket)
        #expect(p.ticket?.class == e.ticketClass)
    }

    @Test func draftAndPrototypeAreNotLexiconWords() throws {
        let draft = try parse("Draft idempotency plan")
        #expect(draft.kind == .note)
        #expect(!draft.kindMatched)
        let proto = try parse("Prototype webhook replay tool ACME-000000")
        #expect(proto.kind == .note)
        #expect(proto.ticket == Ticket(key: "ACME-000000", class: .selfInitiated))
        let done = try parse("Prototyped webhook replay tool ACME-000000")
        #expect(done.kind == .initiativeStarted)
        #expect(done.title == "Prototyped webhook replay tool ACME-000000")
    }

    @Test func estimateTildeExample() throws {
        let p = try parse("Pair on flaky ledger test est~1h #quality")
        #expect(p.durationS == 3600)
        #expect(p.tags == ["quality"])
        #expect(p.title == "Pair on flaky ledger test")
        #expect(p.tokens.map(\.kind) == [.duration, .tag])
    }

    @Test func titleKeepsVerbAndTicket() throws {
        let p = try parse("Fixed flaky ledger test with deterministic clock ACME-482913 @10:30 for 45 min #quality.")
        #expect(p.title == "Fixed flaky ledger test with deterministic clock ACME-482913")
        #expect(clock(p) == "10:30")
        #expect(p.durationS == 2700)
        #expect(p.tokens.map(\.kind) == [.kind, .ticket, .time, .duration, .tag])
        #expect(p.tokens[0].text == "Fixed")
    }

    // MARK: Lexicon

    struct Word: Sendable, CustomTestStringConvertible {
        let word: String
        let kind: EntryKind
        var testDescription: String { word }
    }

    static let lexicon: [Word] = ([(String, EntryKind)]([
        ("reviewed", .reviewGiven), ("approved", .reviewGiven), ("merged", .prMerged), ("shipped", .shipped),
        ("released", .shipped), ("fixed", .workDone), ("implemented", .workDone), ("built", .workDone),
        ("refactored", .workDone), ("finished", .workDone), ("raised", .discussionRaised),
        ("proposed", .discussionRaised), ("brought up", .discussionRaised), ("challenged", .decisionChallenged),
        ("pushed back", .decisionChallenged), ("led", .meetingLed), ("ran", .meetingLed),
        ("facilitated", .meetingLed), ("demoed", .meetingLed), ("attended", .meetingAttended),
        ("joined", .meetingAttended), ("sync", .meetingAttended), ("1:1", .meetingAttended),
        ("helped", .mentoring), ("paired", .mentoring), ("mentored", .mentoring), ("unblocked", .mentoring),
        ("paged", .incidentHandled), ("incident", .incidentHandled), ("hotfix", .incidentHandled),
        ("mitigated", .incidentHandled), ("prototyped", .initiativeStarted), ("kicked off", .initiativeStarted),
        ("automated", .initiativeStarted), ("initiative", .initiativeStarted), ("wrote", .docWritten),
        ("drafted", .docWritten), ("RFC", .docWritten), ("ADR", .docWritten), ("code review", .reviewGiven),
        ("PR review", .reviewGiven), ("reviewing", .reviewGiven), ("opened a PR", .prOpened), ("PR opened", .prOpened),
    ])).map { Word(word: $0.0, kind: $0.1) }

    @Test(arguments: lexicon)
    func everyLexiconWord(_ w: Word) throws {
        for line in ["\(w.word) the thing", "The thing \(w.word.uppercased())", "So we \(w.word.capitalized) it."] {
            let p = try parse(line)
            #expect(p.kind == w.kind, "\(line)")
            #expect(p.kindMatched)
        }
    }

    @Test func wholeWordsOnly() throws {
        for line in ["A review of things", "Preview things", "asynchronous work", "ranch visit", "builtin", "the led display"] {
            let p = try parse(line)
            if line == "the led display" {
                #expect(p.kind == .meetingLed)
            } else {
                #expect(p.kind == .note, "\(line)")
                #expect(!p.kindMatched)
            }
        }
    }

    @Test func firstGroupWins() throws {
        #expect(try parse("Reviewed settlement batching RFC").kind == .reviewGiven)
        #expect(try parse("Drafted idempotency ADR").kind == .docWritten)
        #expect(try parse("Raised retry storms in arch sync").kind == .discussionRaised)
        #expect(try parse("Fixed it after the incident").kind == .workDone)
        #expect(try parse("Wrote up the incident").kind == .incidentHandled)
        #expect(try parse("Joined the sync and reviewed the doc").kind == .reviewGiven)
        #expect(try parse("Merged the fix").kind == .prMerged)
    }

    @Test func earliestWordWinsInsideTheDeliveryGroup() throws {
        #expect(try parse("Shipped the fix, PR merged").kind == .shipped)
        #expect(try parse("PR merged, then released").kind == .prMerged)
    }

    @Test func reviewAndOpenedPhrases() throws {
        for line in ["Code review of the retry fix", "PR review for ACME-482913", "Reviewing the settlement doc", "Reviewing https://git.example.com/acme/api/pull/88"] {
            let p = try parse(line)
            #expect(p.kind == .reviewGiven, "\(line)")
            #expect(p.kindMatched, "\(line)")
        }
        for line in ["Opened a PR for the retry fix", "PR opened for ACME-482913"] {
            let p = try parse(line)
            #expect(p.kind == .prOpened, "\(line)")
            #expect(p.kindMatched, "\(line)")
        }
        // A bare "review" says too little: the line stays a note, so the person sees the miss.
        for line in ["Quick review", "Review of the plan", "Did a review"] {
            let p = try parse(line)
            #expect(p.kind == .note, "\(line)")
            #expect(!p.kindMatched, "\(line)")
        }
        // The later state wins: merged beats opened.
        #expect(try parse("Opened a PR and merged it").kind == .prMerged)
        // "pr review" is a phrase, not two words anywhere in the line.
        #expect(try parse("PR then a review").kind == .note)
    }

    // MARK: Time

    struct TimeCase: Sendable, CustomTestStringConvertible {
        let line: String
        let clock: String?
        var testDescription: String { line }
    }

    static let times: [TimeCase] = [
        TimeCase(line: "Standup @10:30", clock: "10:30"),
        TimeCase(line: "Standup @9", clock: "09:00"),
        TimeCase(line: "Standup @9pm", clock: "21:00"),
        TimeCase(line: "Standup at 3pm", clock: "15:00"),
        TimeCase(line: "Standup at 3:15pm", clock: "15:15"),
        TimeCase(line: "Standup at 15:00", clock: "15:00"),
        TimeCase(line: "Standup at 12am", clock: "00:00"),
        TimeCase(line: "Standup at 12pm", clock: "12:00"),
        TimeCase(line: "Standup at 12:30 AM", clock: "00:30"),
        TimeCase(line: "Standup at 11:59pm", clock: "23:59"),
        TimeCase(line: "Standup @23:59", clock: "23:59"),
        TimeCase(line: "Standup @25", clock: nil),
        TimeCase(line: "Standup @10:75", clock: nil),
        TimeCase(line: "Standup at 13pm", clock: nil),
        TimeCase(line: "Standup at 0pm", clock: nil),
        TimeCase(line: "Stuck at 3 retries", clock: nil),
        TimeCase(line: "mail a@10.example.com", clock: nil),
    ]

    @Test(arguments: times)
    func timeForms(_ c: TimeCase) throws {
        let p = try parse(c.line)
        #expect(clock(p) == c.clock)
        if c.clock != nil {
            #expect(p.title == "Standup")
            #expect(p.tokens.contains { $0.kind == .time })
            #expect(p.day == (try date("2026-10-29")))
        } else {
            #expect(!p.tokens.contains { $0.kind == .time })
            #expect(p.title == c.line)
        }
    }

    @Test func timeLandsOnTheDayToken() throws {
        let p = try parse("Standup yesterday at 9:05am")
        #expect(p.day == (try date("2026-10-28")))
        let at = try #require(p.occurredAt)
        #expect(Timestamp.clockTime(at, in: Self.zone) == "09:05")
        #expect(DayBoundary.standard.day(of: at, in: Self.zone) == (try date("2026-10-28")))
        #expect(p.backfilled)
    }

    @Test func timeBeforeTheBoundaryBelongsToTheSameWorkday() throws {
        let p = try parse("Late deploy @1:30am")
        let at = try #require(p.occurredAt)
        #expect(DayBoundary.standard.day(of: at, in: Self.zone) == p.day)
        #expect(clock(p) == "01:30")
    }

    // MARK: Day

    struct DayCase: Sendable, CustomTestStringConvertible {
        let line: String
        let day: String
        var testDescription: String { line }
    }

    static let days: [DayCase] = [
        DayCase(line: "Standup today", day: "2026-10-29"),
        DayCase(line: "Standup yesterday", day: "2026-10-28"),
        DayCase(line: "Standup mon", day: "2026-10-26"),
        DayCase(line: "Standup Monday", day: "2026-10-26"),
        DayCase(line: "Standup tue", day: "2026-10-27"),
        DayCase(line: "Standup Wed", day: "2026-10-28"),
        DayCase(line: "Standup thu", day: "2026-10-22"),
        DayCase(line: "Standup thursday", day: "2026-10-22"),
        DayCase(line: "Standup fri", day: "2026-10-23"),
        DayCase(line: "Standup Sat", day: "2026-10-24"),
        DayCase(line: "Standup Sunday", day: "2026-10-25"),
        DayCase(line: "Standup 27 oct", day: "2026-10-27"),
        DayCase(line: "Standup oct 27", day: "2026-10-27"),
        DayCase(line: "Standup 27 Oct 2025", day: "2025-10-27"),
        DayCase(line: "Standup Oct 27, 2025", day: "2025-10-27"),
        DayCase(line: "Standup 3rd October", day: "2026-10-03"),
        DayCase(line: "Standup 2026-10-27", day: "2026-10-27"),
        DayCase(line: "Standup Wed 28 Oct", day: "2026-10-28"),
        DayCase(line: "Standup 29 Oct", day: "2026-10-29"),
        DayCase(line: "Standup 30 Oct", day: "2025-10-30"),
        DayCase(line: "Standup dec 25", day: "2025-12-25"),
        DayCase(line: "Standup Nov 1", day: "2025-11-01"),
    ]

    @Test(arguments: days)
    func dayForms(_ c: DayCase) throws {
        let p = try parse(c.line)
        #expect(p.day == (try date(c.day)))
        #expect(p.title == "Standup")
        #expect(p.backfilled == (c.day != "2026-10-29"))
        #expect(p.tokens.filter { $0.kind == .day }.count == 1)
    }

    @Test func weekdayOnTheSameWeekdayMeansAWeekAgo() throws {
        #expect(try parse("Standup thu").day == (try date("2026-10-22")))
    }

    @Test func futureDayHandling() throws {
        // ISO in the future: ignored, left in the title.
        let iso = try parse("Plan 2026-11-02")
        #expect(iso.day == (try date("2026-10-29")))
        #expect(iso.title == "Plan 2026-11-02")
        #expect(iso.tokens.isEmpty)
        // Day and month later than today: previous year.
        #expect(try parse("Plan 2 nov").day == (try date("2025-11-02")))
        // Explicit future year: ignored.
        let year = try parse("Plan 2 nov 2027")
        #expect(year.day == (try date("2026-10-29")))
        // Invalid calendar dates are not tokens.
        #expect(try parse("Plan 31 feb").tokens.isEmpty)
        #expect(try parse("Plan 2026-02-30").tokens.isEmpty)
    }

    @Test func ordinaryWordsAreNotDays() throws {
        for line in ["I sat with the team", "sun was out", "Monitor alerts", "wed the two systems", "Today's plan is long"] {
            let p = try parse(line)
            #expect(!p.tokens.contains { $0.kind == .day }, "\(line)")
        }
    }

    @Test func boundaryDecidesToday() throws {
        // 02:00 local on Friday 30 Oct is still Thursday's workday.
        let late = try #require(ISO8601DateFormatter().date(from: "2026-10-30T02:00:00+05:30"))
        let ctx = CaptureContext(now: late, zone: Self.zone, classifier: try TicketClassifier(rules: .standard))
        let p = CaptureParser.parse("Standup", context: ctx)
        #expect(p.day == (try date("2026-10-29")))
        #expect(!p.backfilled)
        #expect(CaptureParser.parse("Standup thu", context: ctx).day == (try date("2026-10-22")))
    }

    // MARK: Duration

    struct DurCase: Sendable, CustomTestStringConvertible {
        let line: String
        let seconds: Int64?
        var testDescription: String { line }
    }

    static let durations: [DurCase] = [
        DurCase(line: "Work ~2h", seconds: 7200),
        DurCase(line: "Work 2h", seconds: 7200),
        DurCase(line: "Work 45m", seconds: 2700),
        DurCase(line: "Work 1h30", seconds: 5400),
        DurCase(line: "Work 1h30m", seconds: 5400),
        DurCase(line: "Work for 1h30", seconds: 5400),
        DurCase(line: "Work for 45 min", seconds: 2700),
        DurCase(line: "Work 90 minutes", seconds: 5400),
        DurCase(line: "Work for 2 hours", seconds: 7200),
        DurCase(line: "Work ~1.5h", seconds: 5400),
        DurCase(line: "Work 24h", seconds: 86_400),
        DurCase(line: "Work 25h", seconds: nil),
        DurCase(line: "Work 1500m", seconds: nil),
        DurCase(line: "Work 0m", seconds: nil),
        DurCase(line: "Work 1h75", seconds: nil),
        DurCase(line: "Work ACME-2h", seconds: nil),
    ]

    @Test(arguments: durations)
    func durationForms(_ c: DurCase) throws {
        let p = try parse(c.line)
        #expect(p.durationS == c.seconds)
        if c.seconds != nil {
            #expect(p.title == "Work")
        } else {
            #expect(!p.tokens.contains { $0.kind == .duration })
        }
    }

    // MARK: Count

    struct CountCase: Sendable, CustomTestStringConvertible {
        let line: String
        let kind: EntryKind
        let qty: Int64
        var testDescription: String { line }
    }

    static let counts: [CountCase] = [
        CountCase(line: "3 reviews", kind: .reviewGiven, qty: 3),
        CountCase(line: "1 review", kind: .reviewGiven, qty: 1),
        CountCase(line: "attended 4 meetings", kind: .meetingAttended, qty: 4),
        CountCase(line: "2 incidents", kind: .incidentHandled, qty: 2),
        CountCase(line: "5 PRs merged", kind: .prMerged, qty: 5),
        CountCase(line: "2 discussions", kind: .discussionRaised, qty: 2),
        CountCase(line: "4 sessions", kind: .note, qty: 4),
        CountCase(line: "reviewed 3 PRs", kind: .reviewGiven, qty: 3),
        CountCase(line: "50 reviews", kind: .reviewGiven, qty: 50),
        CountCase(line: "3 reviews today ~1h", kind: .reviewGiven, qty: 3),
    ]

    @Test(arguments: counts)
    func countForms(_ c: CountCase) throws {
        let p = try parse(c.line)
        #expect(p.kind == c.kind)
        #expect(p.quantity == c.qty)
        #expect(p.kindMatched)
        #expect(p.tokens.contains { $0.kind == .count })
    }

    @Test func countOutOfRangeIsIgnored() throws {
        for line in ["0 reviews", "51 reviews", "999 meetings"] {
            let p = try parse(line)
            #expect(p.quantity == 1, "\(line)")
            #expect(!p.tokens.contains { $0.kind == .count })
            #expect(p.kind == .note)
        }
    }

    @Test func countStaysInTheTitle() throws {
        #expect(try parse("3 reviews #team").title == "3 reviews")
        #expect(try parse("attended 4 meetings").title == "attended 4 meetings")
    }

    // MARK: Links

    @Test func linkKinds() throws {
        let p = try parse(
            "Merged https://git.example.com/acme/ledger/pull/412 for https://tickets.example.com/browse/ACME-482913 see https://docs.example.com/page.")
        #expect(
            p.links == [
                Link(kind: .pr, url: "https://git.example.com/acme/ledger/pull/412"),
                Link(kind: .ticket, url: "https://tickets.example.com/browse/ACME-482913"),
                Link(kind: .other, url: "https://docs.example.com/page"),
            ])
        #expect(p.tokens.filter { $0.kind == .link }.count == 3)
        #expect(p.ticket?.key == "ACME-482913")
        #expect(p.kind == .prMerged)
    }

    // A URL that becomes a link leaves the title (docs/PLAN.md T4.17); the link chip and the row's link button carry it.
    @Test func aLinkLeavesTheTitle() throws {
        let pr = "https://git.example.com/acme/api/pull/88"
        let p = try parse("Reviewed \(pr)")
        #expect(p.title == "Reviewed")
        #expect(p.links == [Link(kind: .pr, url: pr)])
        #expect(p.kind == .reviewGiven)
        // The token still sits where the URL is in the line, for the capture bar's chip.
        let token = try #require(p.tokens.first { $0.kind == .link })
        #expect(token.text == pr)
        #expect(try parse("Merged the retry fix \(pr) @10:30 #team.").title == "Merged the retry fix")
        #expect(try parse("Reviewed: \(pr)").title == "Reviewed")
        #expect(try parse("Merged (\(pr))").title == "Merged")
        #expect(try parse("Reviewed \(pr) and the notes").title == "Reviewed and the notes")
    }

    @Test func aLineThatIsOnlyALinkIsTitledByTheLinksName() throws {
        let pr = try parse("https://git.example.com/acme/api/pull/88")
        #expect(pr.title == "PR #88 in acme/api")
        #expect(pr.links.count == 1 && pr.kind == .note)
        #expect(try parse("  https://git.example.com/acme/api/pull/88/files?diff=split#top  ").title == "PR #88 in acme/api")
        #expect(try parse("https://git.example.com/acme/api/pull/88 @14:30 ~20m #team").title == "PR #88 in acme/api")
        #expect(try parse("(https://git.example.com/acme/api/pull/88)").title == "PR #88 in acme/api")
        #expect(try parse("https://tickets.example.com/browse/ACME-482913").title == "ACME-482913")
        #expect(try parse("https://docs.example.com/design/retry").title == "docs.example.com")
        // The first link names the line when there are several.
        #expect(try parse("https://git.example.com/acme/api/pull/88 https://docs.example.com/x").title == "PR #88 in acme/api")
        // The ticket in a browse URL is still the line's ticket.
        #expect(try parse("https://tickets.example.com/browse/ACME-482913").ticket?.key == "ACME-482913")
    }

    @Test func aLinkThatIsNotKeptStaysInTheTitle() throws {
        let line = "Look https://bob:pw@git.example.com/acme/x/pull/10"
        let p = try parse(line)
        #expect(p.links.isEmpty)
        #expect(p.title == line)
        #expect(!p.tokens.contains { $0.kind == .link })
        // A sixth link is not a link, so it stays; a repeat is the same link, so it goes.
        let urls = (1...6).map { "https://example.com/p/\($0)" }
        let many = try parse("See " + urls.joined(separator: " ") + " https://example.com/p/1")
        #expect(many.links.count == 5)
        #expect(many.title == "See https://example.com/p/6")
    }

    @Test func linkNames() throws {
        func name(_ url: String) -> (String, String) { (Link.inferred(url: url).displayName, Link.inferred(url: url).titleName) }
        #expect(name("https://git.example.com/acme/api/pull/88") == ("PR #88", "PR #88 in acme/api"))
        #expect(name("https://git.example.com/acme/api/pull/88/files?x=1#y") == ("PR #88", "PR #88 in acme/api"))
        #expect(name("https://git.example.com/pull/88") == ("PR #88", "PR #88"))
        #expect(name("https://tickets.example.com/browse/ACME-12") == ("ACME-12", "ACME-12"))
        #expect(name("https://docs.example.com/page?q=1") == ("docs.example.com", "docs.example.com"))
        #expect(name("https://git.example.com/acme/api/pull/x") == ("git.example.com", "git.example.com"))
        #expect(name("not a url") == ("not a url", "not a url"))
    }

    @Test func unsafeSchemesAreDropped() throws {
        for line in ["Look javascript:alert(1)", "Look http://example.com/x", "Look ftp://example.com/x", "Look file:///etc/passwd"] {
            let p = try parse(line)
            #expect(p.links.isEmpty, "\(line)")
        }
        #expect(try parse("Look javascript:alert(1)").title == "Look javascript:alert(1)")
    }

    @Test func linksAreCappedAndUnique() throws {
        let urls = (1...8).map { "https://example.com/p/\($0)" }
        let p = try parse(urls.joined(separator: " ") + " https://example.com/p/1")
        #expect(p.links.count == 5)
        #expect(p.links.map(\.url) == Array(urls.prefix(5)))
    }

    @Test func urlContentsAreNotParsedAsTokens() throws {
        let p = try parse("See https://example.com/2026-10-27/mon/#top/reviewed/yesterday")
        #expect(p.day == (try date("2026-10-29")))
        #expect(p.tags.isEmpty)
        #expect(p.kind == .note)
        #expect(p.links.count == 1)
    }

    // MARK: Tags

    @Test func tags() throws {
        let p = try parse("Fix #Quality and #retry_budget #quality #a-b")
        #expect(p.tags == ["quality", "retry_budget", "a-b"])
        #expect(p.title == "Fix and")
        #expect(p.tokens.filter { $0.kind == .tag }.count == 4)
    }

    @Test func numericHashIsNotATag() throws {
        let p = try parse("PR #412 landed")
        #expect(p.tags.isEmpty)
        #expect(p.title == "PR #412 landed")
    }

    // MARK: Title

    @Test func titleRules() throws {
        #expect(try parse("  Fixed   the\tthing   ").title == "Fixed the thing")
        #expect(try parse("Fixed it at 3pm.").title == "Fixed it")
        #expect(try parse("Fixed it...").title == "Fixed it..")
        #expect(try parse("Fixed it yesterday @9:30 ~2h #x").title == "Fixed it")
    }

    @Test func emptyTitleFallsBackToTheLine() throws {
        let p = try parse("  @10:30 #quality  ")
        #expect(p.title == "@10:30 #quality")
        #expect(p.tags == ["quality"])
        #expect(try parse("").title == "")
        #expect(try parse("   ").title == "")
    }

    @Test func tokensAreInOrderAndExact() throws {
        let line = "#a Fixed ACME-482913 at 3pm for 1h30 yesterday"
        let p = try parse(line)
        #expect(p.tokens.map(\.kind) == [.tag, .kind, .ticket, .time, .duration, .day])
        for t in p.tokens { #expect(String(line[t.range]) == t.text) }
        #expect(p.tokens.map(\.text) == ["#a", "Fixed", "ACME-482913", "at 3pm", "for 1h30", "yesterday"])
    }

    // MARK: Transcript

    @Test func transcript() throws {
        let text = """
            Wed 28 Oct
            - Reviewed settlement batching RFC ACME-482913
            • Paired on the flaky ledger test ~1h

            * 3 reviews
            1. Raised retry storms in arch sync @10:30
            Thu
            - Standup notes
            """
        let items = CaptureParser.parseTranscript(text, context: try context())
        #expect(items.count == 5)
        let wed = try date("2026-10-28")
        #expect(items[0].title == "Reviewed settlement batching RFC ACME-482913")
        #expect(items[0].day == wed)
        #expect(items[0].backfilled)
        #expect(items[1].title == "Paired on the flaky ledger test")
        #expect(items[1].durationS == 3600)
        #expect(items[2].quantity == 3)
        #expect(items[2].kind == .reviewGiven)
        #expect(items[3].kind == .discussionRaised)
        #expect(clock(items[3]) == "10:30")
        #expect(items[3].day == wed)
        // "Thu" is a day header relative to today (a week ago), applying to the last line.
        #expect(items[4].title == "Standup notes")
        #expect(items[4].day == (try date("2026-10-22")))
    }

    @Test func transcriptYesterdayHeaderAndInlineDayWins() throws {
        let text = "yesterday:\n- Fixed a bug\n- Fixed another today\r\n- \n\u{2022} Wrote docs \u{2022} Led a retro"
        let items = CaptureParser.parseTranscript(text, context: try context())
        #expect(items.map(\.title) == ["Fixed a bug", "Fixed another", "Wrote docs", "Led a retro"])
        #expect(items.map(\.day) == [try date("2026-10-28"), try date("2026-10-29"), try date("2026-10-28"), try date("2026-10-28")])
    }

    @Test func transcriptKeepsOneToOneAndNumbers() throws {
        let items = CaptureParser.parseTranscript("1:1 with Sam\n3 reviews", context: try context())
        #expect(items.count == 2)
        #expect(items[0].kind == .meetingAttended)
        #expect(items[1].quantity == 3)
        #expect(CaptureParser.parseTranscript("", context: try context()).isEmpty)
        #expect(CaptureParser.parseTranscript("\n \n-\n", context: try context()).isEmpty)
    }

    // MARK: Robustness

    @Test func awkwardInputs() throws {
        let long = String(repeating: "Fixed @9 ~2h #t ACME-123456 https://example.com/x ", count: 200)
        let inputs = [
            "🙂🙂🙂 fixed 👨‍👩‍👧‍👦 at 3pm", "שלום reviewed עולם @10:30", "!!!???...,,,;;;", String(repeating: "#", count: 5000),
            String(repeating: "@9 ", count: 3000), long, "\u{0}\u{1}\u{7f}", "e\u{301} 3 reviews\u{301}", "https://",
            "at", "~", "for", "1h", "3 ", "- ", "#", "@", "ACME-", "27", "oct", "2026-10-",
        ]
        for line in inputs {
            let p = try parse(line)
            for t in p.tokens { #expect(String(line[t.range]) == t.text) }
        }
        #expect(try parse(long).links.count == 1)
    }

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func fuzzNeverCrashes() throws {
        let ctx = try context()
        let pieces = [
            "fixed", "Reviewed", "at", "3pm", "@", "10:30", "~", "2h", "1h30", "for", "min", "#", "tag", "yesterday",
            "mon", "27", "oct", "2026-10-27", "https://example.com/pull/12", "https://", "ACME-482913", "ACME-000000",
            "3", "reviews", "PRs", "merged", "1:1", " ", "  ", "\n", "- ", "•", ".", ",", "🙂", "שלום", "é", "\u{301}",
            "99999999999999999999", "12am", "pm", "browse/", "(", ")",
        ]
        var rng = SplitMix(state: 20_261_029)
        for _ in 0..<1000 {
            var line = ""
            for _ in 0..<Int.random(in: 0...40, using: &rng) {
                line += pieces.randomElement(using: &rng) ?? ""
                if Bool.random(using: &rng) { line += " " }
            }
            let p = CaptureParser.parse(line, context: ctx)
            for t in p.tokens { #expect(String(line[t.range]) == t.text) }
            #expect((1...50).contains(p.quantity))
            _ = CaptureParser.parseTranscript(line, context: ctx)
        }
    }

    @Test func deterministic() throws {
        let line = "Prototyped thing ACME-000000 yesterday at 9am ~2h #x"
        #expect(try parse(line) == (try parse(line)))
    }
}
