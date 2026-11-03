// Recaps (docs/SPEC.md section 5.5): short stories built from the findings engine. Every headline and paragraph is a
// finding's sentence, split at its first full stop, or fixed copy that states no figure. A frame whose figures are
// unknown is left out, and nothing is written in place of an unknown number.
import CadenceCore
import Foundation

/// A run of tiles of one look, and what they count.
public struct RecapTiles: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        /// The thing the frame is about.
        case solid
        /// A second thing, side by side with the first.
        case outlined
        /// Counted, but neither of the others.
        case faint
    }

    public var style: Style
    public var count: Int
    /// What one tile is, after its count: "4 merged".
    public var label: String

    public init(_ style: Style, _ count: Int, _ label: String) {
        self.style = style
        self.count = count
        self.label = label
    }
}

/// One delivered thing on the third weekly frame.
public struct Delivered: Sendable, Equatable {
    public var title: String
    public var selfStarted: Bool

    public init(title: String, selfStarted: Bool) {
        self.title = title
        self.selfStarted = selfStarted
    }
}

public struct RecapFrame: Sendable, Equatable {
    public var caption: String
    public var pose: TempoPose.Name
    /// The water where the frame has a figure for it, otherwise the pose's own.
    public var level: Double?
    public var headline: String
    public var paragraph: String
    /// Delivered titles, in order, for the frame that lists them.
    public var delivered: [Delivered]
    public var tiles: [RecapTiles]
    public var deep: RecapDeep

    public init(
        caption: String, pose: TempoPose.Name, level: Double? = nil, headline: String, paragraph: String = "",
        delivered: [Delivered] = [], tiles: [RecapTiles] = [], deep: RecapDeep
    ) {
        self.caption = caption
        self.pose = pose
        self.level = level
        self.headline = headline
        self.paragraph = paragraph
        self.delivered = delivered
        self.tiles = tiles
        self.deep = deep
    }

    public var tempo: TempoSpec { TempoSpec(pose: pose, level: level) }

    /// Every tile, in drawing order.
    public var tileCount: Int { tiles.reduce(0) { $0 + $1.count } }

    /// Whether the grid is drawn: some tiles, and few enough that each is one thing.
    public var drawsTiles: Bool { tileCount > 0 && tileCount <= RecapTokens.maxTiles }

    /// About square, never wider than the grid allows.
    public var columns: Int {
        let n = max(1, tileCount)
        return min(RecapTokens.maxColumns, Int(Double(n).squareRoot().rounded(.up)))
    }

    /// The grid's widest: its columns at the largest tile, with their gaps.
    public var gridWidth: CGFloat {
        let n = CGFloat(columns)
        return min(RecapTokens.gridWidth, n * RecapTokens.tileMax + (n - 1) * CadenceSpace.s8)
    }

    /// The tiles as one sentence, for VoiceOver and the legend: "4 merged, 12 reviewed".
    public var tileSummary: String {
        tiles.filter { $0.count > 0 }.map { "\($0.count) \($0.label)" }.joined(separator: ", ")
    }

    /// The paragraph as shown: the delivered titles when there are any, the first few only.
    public func shownParagraph(discreet: Bool) -> String {
        guard !delivered.isEmpty else { return paragraph }
        let shown = delivered.prefix(RecapTokens.shownTitles)
        var text = Self.sentences(Array(shown), discreet: discreet)
        let more = delivered.count - shown.count
        if more > 0 { text += String(localized: " And \(more) more.") }
        return text
    }

    /// "Retry budget groundwork. Rate limiter tuning, self-started."
    static func sentences(_ items: [Delivered], discreet: Bool, from start: Int = 0) -> String {
        items.enumerated().map { Self.line($0.element, index: start + $0.offset, discreet: discreet) + "." }.joined(separator: " ")
    }

    static func line(_ item: Delivered, index: Int, discreet: Bool) -> String {
        var title = discreet ? String(localized: "Item \(index + 1)") : item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasSuffix(".") { title.removeLast() }
        return title + (item.selfStarted ? String(localized: ", self-started") : "")
    }
}

public struct Recap: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case weekly, monthly, cycle, oneOnOne
    }

    public var kind: Kind
    /// "Week 43", "October", "This cycle", "Since my last 1:1".
    public var name: String
    /// The range in words: "Week 43, 19 to 23 Oct". The first frame's caption.
    public var title: String
    /// The days alone, for a compact row: "19 to 23 Oct".
    public var span: String
    public var from: LocalDate
    public var to: LocalDate
    public var frames: [RecapFrame]
    /// The plan done share, for the hub card. Nil when unknown.
    public var planPercent: Int?
    /// The plan finding's first sentence, for a row of earlier recaps: "94% of your plan got done."
    public var planLine: String?
    /// The hub card's line: the finding that fits it best.
    public var note: String?

    public var id: String { "\(kind.rawValue) \(from) \(to)" }

    public init(
        kind: Kind, name: String, title: String, span: String, from: LocalDate, to: LocalDate, frames: [RecapFrame],
        planPercent: Int? = nil, planLine: String? = nil, note: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.title = title
        self.span = span
        self.planLine = planLine
        self.from = from
        self.to = to
        self.frames = frames
        self.planPercent = planPercent
        self.note = note
    }

    // MARK: copy

    /// The whole recap as plain text: the range, then each frame's caption and sentences.
    public func plainText(discreet: Bool = false) -> String {
        var blocks = [title]
        for frame in frames {
            var lines: [String] = []
            if frame.caption != title { lines.append(frame.caption) }
            if frame.delivered.isEmpty {
                lines.append([frame.headline, frame.paragraph].filter { !$0.isEmpty }.joined(separator: " "))
            } else {
                lines.append(frame.headline)
                lines += frame.delivered.enumerated().map { "- " + RecapFrame.line($0.element, index: $0.offset, discreet: discreet) }
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The whole recap as Markdown: the range as a heading, each frame under its caption, the headline in bold.
    public func markdown(discreet: Bool = false) -> String {
        var blocks = ["## " + Self.escaped(title)]
        for frame in frames {
            if frame.caption != title { blocks.append("### " + Self.escaped(frame.caption)) }
            let lead = "**" + Self.escaped(frame.headline) + "**"
            if frame.delivered.isEmpty {
                blocks.append(frame.paragraph.isEmpty ? lead : lead + " " + Self.escaped(frame.paragraph))
            } else {
                blocks.append(lead)
                blocks.append(
                    frame.delivered.enumerated().map {
                        "- " + Self.escaped(RecapFrame.line($0.element, index: $0.offset, discreet: discreet))
                    }.joined(separator: "\n"))
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// A title is the person's own text, so Markdown's marks in it are escaped and read as typed.
    static func escaped(_ text: String) -> String {
        let marks: Set<Character> = ["\\", "`", "*", "_", "[", "]", "#", "<", ">", "|", "~"]
        var out = ""
        for c in text {
            if marks.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

/// Everything the Recap section shows.
public struct RecapHub: Sendable, Equatable {
    public var today: LocalDate
    public var weekly: Recap
    public var monthly: Recap
    /// Nil until a cycle start date is set.
    public var cycle: Recap?
    public var oneOnOne: Recap
    public var oneOnOneDate: LocalDate
    /// The two weeks before the last full week, then last month.
    public var earlier: [Recap]

    public init(
        today: LocalDate, weekly: Recap, monthly: Recap, cycle: Recap?, oneOnOne: Recap, oneOnOneDate: LocalDate, earlier: [Recap]
    ) {
        self.today = today
        self.weekly = weekly
        self.monthly = monthly
        self.cycle = cycle
        self.oneOnOne = oneOnOne
        self.oneOnOneDate = oneOnOneDate
        self.earlier = earlier
    }

    public static let copyNote = String(localized: "Every recap copies as plain text or Markdown.")
    public static let cycleNote = String(localized: "A cycle recap appears once you set a cycle start date in Settings.")

    /// The line under the cards.
    public var note: String { cycle == nil ? Self.copyNote + " " + Self.cycleNote : Self.copyNote }
}

/// Builds recaps from a journal's summaries. Pure reads: call it inside one read transaction.
public enum RecapBuilder {
    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let fullMonthNames = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
    ]

    /// How far back the 1:1 date starts when none is chosen.
    public static let defaultOneOnOneDays = 14

    public static func hub(_ journal: Journal, today: LocalDate, oneOnOne: LocalDate?) throws(CadenceError) -> RecapHub {
        let monday = today.adding(days: -(Weekday.allCases.firstIndex(of: today.weekday) ?? 0))
        let lastWeek = monday.adding(days: -7)
        let firstOfMonth = LocalDate(year: today.year, month: today.month, day: 1) ?? today
        let date = min(oneOnOne ?? today.adding(days: -defaultOneOnOneDays), today)

        var earlier = [try weekly(journal, monday: lastWeek.adding(days: -7)), try weekly(journal, monday: lastWeek.adding(days: -14))]
        let lastMonthEnd = firstOfMonth.adding(days: -1)
        if let start = LocalDate(year: lastMonthEnd.year, month: lastMonthEnd.month, day: 1) {
            earlier.append(try monthly(journal, from: start, to: lastMonthEnd, today: today))
        }
        return RecapHub(
            today: today, weekly: try weekly(journal, monday: lastWeek),
            monthly: try monthly(journal, from: firstOfMonth, to: today, today: today),
            cycle: try cycle(journal, today: today), oneOnOne: try Self.oneOnOne(journal, since: date, today: today),
            oneOnOneDate: date, earlier: earlier)
    }

    // MARK: the four recaps

    /// The Monday to Sunday week from `monday`: delivery, the plan, what was delivered, beyond the plan, AI.
    public static func weekly(_ journal: Journal, monday: LocalDate) throws(CadenceError) -> Recap {
        let sunday = monday.adding(days: 6)
        let s = try journal.summary(from: monday, to: sunday, label: "week")
        let f = Found(s)
        let week = String(localized: "Week \(Findings.isoWeek(monday))")
        let workdays = LocalDate.range(monday, through: sunday).filter { DayRules(config: journal.config).workdays.contains($0.weekday) }
        let daySpan = span(workdays.first ?? monday, workdays.last ?? sunday)
        let title = "\(week), \(daySpan)"

        var frames: [RecapFrame] = []
        if let delivery = f[.delivery] {
            frames.append(
                RecapFrame(
                    caption: title, pose: .reviewer, headline: delivery.text, paragraph: f[.reviewCadence]?.text ?? "",
                    tiles: deliveryTiles(s), deep: CadenceDeep.butter))
        }
        if let plan = planFrame(s, f, caption: String(localized: "The plan"), pose: .tick, deep: CadenceDeep.blue) { frames.append(plan) }
        let delivered = try self.delivered(journal, from: monday, to: sunday)
        if !delivered.isEmpty {
            frames.append(
                RecapFrame(
                    caption: String(localized: "What you delivered"), pose: .parcel,
                    headline: String(localized: "\(delivered.count) \(delivered.count == 1 ? String(localized: "thing") : String(localized: "things")) shipped."), delivered: delivered,
                    tiles: [
                        RecapTiles(.solid, delivered.filter { !$0.selfStarted }.count, String(localized: "shipped")),
                        RecapTiles(.outlined, delivered.filter(\.selfStarted).count, String(localized: "self-started")),
                    ], deep: CadenceDeep.mint))
        }
        if let presence = f[.presence] {
            let showedUp = presence.figures.objectValue?.values.contains { ($0.intValue ?? 0) > 0 || $0.arrayValue != nil } ?? false
            let kinds = s.kindCounts ?? [:]
            frames.append(
                RecapFrame(
                    caption: String(localized: "Beyond the plan"), pose: .friend, headline: showedUp ? String(localized: "You showed up for people.") : presence.text,
                    paragraph: showedUp ? presence.text : "",
                    tiles: [
                        RecapTiles(.solid, kinds[EntryKind.meetingLed.rawValue] ?? 0, String(localized: "led")),
                        RecapTiles(.outlined, kinds[EntryKind.decisionChallenged.rawValue] ?? 0, String(localized: "challenged")),
                        RecapTiles(.faint, kinds[EntryKind.mentoring.rawValue] ?? 0, String(localized: "mentored")),
                    ], deep: CadenceDeep.rose))
        }
        if let ai = f[.ai] {
            let (head, rest) = split(ai.text)
            var tiles: [RecapTiles] = []
            if let sessions = s.aiSessions {
                tiles = [RecapTiles(.solid, sessions, sessions == 1 ? String(localized: "session") : String(localized: "sessions"))]
            } else if let days = s.aiDays {
                tiles = [RecapTiles(.solid, days, String(localized: "with AI")), RecapTiles(.faint, s.aiCountedDays - days, String(localized: "without"))]
            }
            frames.append(RecapFrame(caption: String(localized: "With AI"), pose: .chat, headline: head, paragraph: rest, tiles: tiles, deep: CadenceDeep.lilac))
        }
        return Recap(
            kind: .weekly, name: week, title: title, span: daySpan, from: monday, to: sunday, frames: frames,
            planPercent: planPercent(s), planLine: f[.plan].map { split($0.text).0 }, note: f[.delivery]?.text)
    }

    /// This month so far, or a whole month: the plan, delivery, consistency.
    public static func monthly(_ journal: Journal, from: LocalDate, to: LocalDate, today: LocalDate) throws(CadenceError) -> Recap {
        let s = try journal.summary(from: from, to: to, label: "month")
        let f = Found(s)
        let month = fullMonthNames[from.month - 1]
        let current = to >= today
        let title = current ? String(localized: "\(month) so far") : month
        var frames: [RecapFrame] = []
        if var plan = planFrame(s, f, caption: title, pose: .scroll, deep: CadenceDeep.blue) {
            if let trend = f[.planTrend] { plan.paragraph = [plan.paragraph, trend.text].filter { !$0.isEmpty }.joined(separator: " ") }
            frames.append(plan)
        }
        if let delivery = f[.delivery] {
            frames.append(
                RecapFrame(
                    caption: String(localized: "Delivery"), pose: .stack, headline: delivery.text, paragraph: f[.selfInitiated]?.text ?? "",
                    tiles: prTiles(s), deep: CadenceDeep.mint))
        }
        if let cadence = f[.reviewCadence], let days = s.reviewDays {
            frames.append(
                RecapFrame(
                    caption: String(localized: "Consistency"), pose: .calendar, headline: cadence.text, paragraph: f[.dayShape]?.text ?? "",
                    tiles: [RecapTiles(.solid, days, String(localized: "reviewed")), RecapTiles(.faint, s.countedWorkdays - days, String(localized: "without a review"))],
                    deep: CadenceDeep.butter))
        }
        return Recap(
            kind: .monthly, name: month, title: title, span: span(from, to), from: from, to: to, frames: frames,
            planPercent: planPercent(s), planLine: f[.plan].map { split($0.text).0 }, note: f[.planTrend]?.text ?? f[.delivery]?.text)
    }

    /// From the cycle start to today. Nil until a cycle start date is set.
    public static func cycle(_ journal: Journal, today: LocalDate) throws(CadenceError) -> Recap? {
        guard let start = journal.config.profile.backfillFrom, start <= today else { return nil }
        let s = try journal.summary(from: start, to: today, label: "cycle")
        let f = Found(s)
        let title = String(localized: "Since \(start.day) \(monthNames[start.month - 1])")
        var frames: [RecapFrame] = []
        if let delivery = f[.delivery] {
            frames.append(
                RecapFrame(
                    caption: title, pose: .metronome, level: level(s), headline: delivery.text, paragraph: f[.plan]?.text ?? "",
                    tiles: deliveryTiles(s), deep: CadenceDeep.lilac))
        }
        if !frames.isEmpty {
            frames.append(
                RecapFrame(
                    caption: String(localized: "Ready to share"), pose: .stamp, headline: String(localized: "Every number is backed by your ledger."),
                    paragraph: String(localized: "Export a proof file from Proof whenever you need one."), deep: CadenceDeep.mint))
        }
        return Recap(
            kind: .cycle, name: String(localized: "This cycle"), title: title, span: span(start, today), from: start, to: today, frames: frames,
            planPercent: planPercent(s), planLine: f[.plan].map { split($0.text).0 }, note: f[.delivery]?.text)
    }

    /// From the day of the last 1:1 through today.
    public static func oneOnOne(_ journal: Journal, since date: LocalDate, today: LocalDate) throws(CadenceError) -> Recap {
        let s = try journal.summary(from: date, to: today)
        let f = Found(s)
        let title = String(localized: "Since your last 1:1 on \(date.day) \(monthNames[date.month - 1])")
        var frames: [RecapFrame] = []
        if let delivery = f[.delivery] {
            frames.append(
                RecapFrame(
                    caption: title, pose: .twoMugs, headline: delivery.text, paragraph: f[.presence]?.text ?? "",
                    tiles: deliveryTiles(s), deep: CadenceDeep.butter))
        }
        if let plan = planFrame(s, f, caption: String(localized: "Worth raising"), pose: .cards, deep: CadenceDeep.rose) { frames.append(plan) }
        return Recap(
            kind: .oneOnOne, name: String(localized: "Since my last 1:1"), title: title, span: span(date, today), from: date, to: today,
            frames: frames, planPercent: planPercent(s), planLine: f[.plan].map { split($0.text).0 }, note: f[.delivery]?.text)
    }

    // MARK: parts

    /// The findings of a summary by kind.
    struct Found {
        let byKind: [FindingKind: Finding]

        init(_ s: Summary) {
            byKind = Dictionary(s.findings.map { ($0.kind, $0) }, uniquingKeysWith: { a, _ in a })
        }

        subscript(_ kind: FindingKind) -> Finding? { byKind[kind] }
    }

    static func planFrame(_ s: Summary, _ f: Found, caption: String, pose: TempoPose.Name, deep: RecapDeep) -> RecapFrame? {
        guard let plan = f[.plan], let done = s.planDone, let total = s.planTotal else { return nil }
        let (head, rest) = split(plan.text)
        let slipped = s.slipsByReason?.values.reduce(0, +) ?? 0
        return RecapFrame(
            caption: caption, pose: pose, level: level(s), headline: head, paragraph: rest,
            tiles: [
                RecapTiles(.solid, done, String(localized: "done")), RecapTiles(.outlined, slipped, String(localized: "slipped")),
                RecapTiles(.faint, max(0, total - done - slipped), String(localized: "dropped or left open")),
            ], deep: deep)
    }

    /// Merged solid, reviewed outlined: only the figures the delivery finding states.
    static func deliveryTiles(_ s: Summary) -> [RecapTiles] {
        var tiles: [RecapTiles] = []
        if let merged = s.mergedPRs { tiles.append(RecapTiles(.solid, merged, String(localized: "merged"))) }
        if let reviews = s.reviews { tiles.append(RecapTiles(.outlined, reviews, String(localized: "reviewed"))) }
        return tiles
    }

    /// Merged PRs by ticket: assigned, self-started, no ticket.
    static func prTiles(_ s: Summary) -> [RecapTiles] {
        guard let merged = s.mergedPRs, let assigned = s.assignedPRs, let own = s.selfInitiatedPRs else { return deliveryTiles(s) }
        return [
            RecapTiles(.solid, assigned, String(localized: "assigned")), RecapTiles(.outlined, own, String(localized: "self-started")),
            RecapTiles(.faint, max(0, merged - assigned - own), String(localized: "no ticket")),
        ]
    }

    static func level(_ s: Summary) -> Double? {
        guard let done = s.planDone, let total = s.planTotal, total > 0 else { return nil }
        return Double(done) / Double(total)
    }

    static func planPercent(_ s: Summary) -> Int? {
        guard let done = s.planDone, let total = s.planTotal, total > 0 else { return nil }
        return GenAIMetrics.percent(Int64(done), of: Int64(total))
    }

    /// A finding as headline and paragraph, split after its first sentence. Findings hold no decimals, so the first
    /// ". " ends the first sentence.
    static func split(_ text: String) -> (String, String) {
        guard let end = text.range(of: ". ") else { return (text, "") }
        return (String(text[..<end.lowerBound]) + ".", String(text[end.upperBound...]))
    }

    /// "19 to 23 Oct", or "28 Sep to 2 Oct" across months (section 6.6).
    static func span(_ a: LocalDate, _ b: LocalDate) -> String {
        if a == b { return "\(a.day) \(monthNames[a.month - 1])" }
        if a.month == b.month && a.year == b.year { return String(localized: "\(a.day) to \(b.day) \(monthNames[b.month - 1])") }
        return String(localized: "\(a.day) \(monthNames[a.month - 1]) to \(b.day) \(monthNames[b.month - 1])")
    }

    /// Merged PRs and shipped entries of the range, accepted, in order; self-started by ticket.
    static func delivered(_ journal: Journal, from: LocalDate, to: LocalDate) throws(CadenceError) -> [Delivered] {
        var items: [Delivered] = []
        var cursor: String?
        repeat {
            let page = try journal.query(
                EntryQuery(from: from, to: to, kinds: [.prMerged, .shipped], statuses: [.accepted], cursor: cursor))
            items += page.entries.map { Delivered(title: $0.title, selfStarted: $0.ticket?.class == .selfInitiated) }
            cursor = page.next
        } while cursor != nil
        return items
    }
}
