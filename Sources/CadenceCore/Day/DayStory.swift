import Foundation

// The answer (docs/SPEC.md section 5.2): one pure function from the day to one state, a headline, a sentence and a
// voice line. Sentences are templates with counts filled in, never invented wording. Every surface reads the same
// story, so the window, the panel, the menu-bar mark and VoiceOver always agree.

public struct DayStory: Sendable, Equatable {
    /// The day states, in the order of section 5.2: the first that applies wins.
    public enum State: String, Sendable, CaseIterable {
        case storeProblem = "store_problem"
        case paused
        case sealed
        case editedAfterWrapUp = "edited_after_wrap_up"
        case yesterdayOpen = "yesterday_open"
        case closedUnsealed = "closed_unsealed"
        case leave, sick, holiday, weekend
        case firstRun = "first_run"
        case firstSync = "first_sync"
        case learning
        case sourceBehind = "source_behind"
        case onCall = "on_call"
        case wrapUpDue = "wrap_up_due"
        case nothingLogged = "nothing_logged"
        case planSettled = "plan_settled"
        case morning, planned
        case inRhythm = "in_rhythm"
        case moreThanUsual = "more_than_usual"
        case fewerThanUsual = "fewer_than_usual"
    }

    /// A day on which nothing is expected.
    public enum DayOff: Sendable, Equatable {
        case leave, sick, holiday, weekend

        /// From the ledger's day kind. Sick leave is declared leave labelled "sick", which is what the panel's
        /// Day off menu writes; any other label is leave.
        public init?(kind: DayKind, label: String?) {
            switch kind {
            case .workday: return nil
            case .weekend: self = .weekend
            case .holiday: self = .holiday
            case .leavePlanned, .leaveUnplanned:
                let sick = label?.trimmingCharacters(in: .whitespaces).lowercased() == "sick"
                self = sick ? .sick : .leave
            }
        }
    }

    /// The last workday, when it is still open in its grace window or closed without a seal.
    public struct Previous: Sendable, Equatable {
        public var date: LocalDate
        public var graceOpen: Bool
        /// Workdays sealed in a row before it.
        public var sealedBefore: Int
        /// Its plan and items logged, for the card that offers to wrap it up.
        public var planned: Int
        public var done: Int
        public var items: Int
        /// Whether it is still the day's answer: only until today has a plan or an item.
        public var leads: Bool

        public init(
            date: LocalDate, graceOpen: Bool, sealedBefore: Int, planned: Int = 0, done: Int = 0, items: Int = 0, leads: Bool = true
        ) {
            self.date = date
            self.graceOpen = graceOpen
            self.sealedBefore = sealedBefore
            self.planned = planned
            self.done = done
            self.items = items
            self.leads = leads
        }
    }

    /// A history import while it runs.
    public struct Import: Sendable, Equatable {
        public var label: String
        public var done: Int
        public var total: Int

        public init(label: String, done: Int, total: Int) {
            self.label = label
            self.done = done
            self.total = total
        }
    }

    /// A source that feeds the count and is in its failure state or overdue.
    public struct Behind: Sendable, Equatable {
        public var source: String
        /// Local clock time of its last good run, such as "13:40".
        public var lastSync: String

        public init(source: String, lastSync: String) {
            self.source = source
            self.lastSync = lastSync
        }
    }

    /// Everything the answer needs, already read from the store and the app. Counts are of today.
    public struct Input: Sendable, Equatable {
        public var date: LocalDate
        public var storeProblem = false
        public var paused = false
        /// Local clock time of today's seal.
        public var sealedAt: String?
        /// Entries that arrived after the seal.
        public var lateAdditions = 0
        public var previous: Previous?
        public var dayOff: DayOff?
        public var firstRun = false
        public var importing: Import?
        public var countedWorkdays = 0
        public var behind: Behind?
        public var onCall = false
        /// The wrap-up reminder time that has passed today, such as "17:30".
        public var wrapUpReminder: String?
        public var planned = 0
        public var resolved = 0
        public var done = 0
        /// Open tasks carried from the last workday, shown before a plan is set.
        public var carried = 0
        /// Items logged today (section 5.1).
        public var items = 0
        public var aiSessions = 0
        /// Usual by now, low to high (section 5.1). Nil when there is no range.
        public var usualByNow: ClosedRange<Int>?

        public init(date: LocalDate) {
            self.date = date
        }
    }

    /// Under this many counted workdays there is no range, and Cadence says it is still learning.
    public static let learningDays = UsualRange.minimumDays

    public var state: State
    public var headline: String
    public var sentence: String
    /// What VoiceOver reads for the menu-bar mark, and the mark's tooltip.
    public var voice: String

    public init(_ day: Input) {
        let state = Self.state(day)
        let (headline, sentence, voice) = Self.words(state, day)
        self.state = state
        self.headline = headline
        self.sentence = sentence
        self.voice = voice
    }

    /// The order of section 5.2.
    static func state(_ d: Input) -> State {
        if d.storeProblem { return .storeProblem }
        if d.paused { return .paused }
        if d.sealedAt != nil { return d.lateAdditions > 0 ? .editedAfterWrapUp : .sealed }
        if let previous = d.previous, previous.leads { return previous.graceOpen ? .yesterdayOpen : .closedUnsealed }
        switch d.dayOff {
        case .leave?: return .leave
        case .sick?: return .sick
        case .holiday?: return .holiday
        case .weekend?: return .weekend
        case nil: break
        }
        if d.firstRun { return .firstRun }
        if d.importing != nil { return .firstSync }
        if d.countedWorkdays < learningDays { return .learning }
        if d.behind != nil { return .sourceBehind }
        if d.onCall { return .onCall }
        if d.wrapUpReminder != nil { return d.planned > 0 || d.items > 0 ? .wrapUpDue : .nothingLogged }
        if d.planned > 0, d.resolved >= d.planned { return .planSettled }
        if d.items == 0 { return d.planned > 0 ? .planned : .morning }
        guard let usual = d.usualByNow else { return .inRhythm }
        if d.items > usual.upperBound { return .moreThanUsual }
        if d.items < usual.lowerBound { return .fewerThanUsual }
        return .inRhythm
    }

    static func words(_ state: State, _ d: Input) -> (String, String, String) {
        let items = count(d.items, "item")
        let open = max(0, d.planned - d.resolved)
        let stillOpen = d.planned == 0 ? nil : open == 0 ? "Your plan is settled." : "\(count(open, "planned task")) \(open == 1 ? "is" : "are") still open."
        let usual = d.usualByNow.map { "usually \($0.lowerBound) to \($0.upperBound) by now" } ?? ""
        func join(_ parts: String?...) -> String { parts.compactMap { $0 }.joined(separator: " ") }

        switch state {
        case .storeProblem:
            return ("I cannot read your log.", "Your data is still on disk and nothing has been changed. Here is what to try.", "Cadence needs attention")
        case .paused:
            return ("Capture is paused.", "Presence and collectors are off until you resume. Anything you log by hand still counts.", "Capture paused")
        case .sealed:
            return (
                d.planned > 0 ? "Plan settled, day closed." : "Day closed.",
                "Sealed at \(d.sealedAt ?? "-"). Everything is accounted for.", "Day sealed"
            )
        case .editedAfterWrapUp:
            let one = d.lateAdditions == 1
            let late = one ? "one late addition" : "\(d.lateAdditions) late additions"
            let arrived = one ? "One item arrived" : "\(d.lateAdditions) items arrived"
            let marked = one ? "It is marked as late" : "They are marked as late"
            return (
                "Sealed, with \(late).", "\(arrived) after your wrap-up. \(marked), and your sealed numbers do not change.",
                "Day sealed, \(late)"
            )
        case .yesterdayOpen:
            let name = weekdayName(d.previous?.date ?? d.date)
            return (
                "\(name) is still open.", "You can wrap it up today, until 23:59. It will be marked as sealed the next morning.",
                "\(name) still open"
            )
        case .closedUnsealed:
            let name = weekdayName(d.previous?.date ?? d.date)
            let before = d.previous?.sealedBefore ?? 0
            let record = before > 0 ? "\(count(before, "day")) \(before == 1 ? "was" : "were") sealed before it, and that record stands." : nil
            return (
                "\(name) closed unsealed.",
                join("That is all it means: its entries are kept, and it is marked as not sealed.", record),
                "\(name) closed unsealed"
            )
        case .leave:
            return ("You are on leave.", "Nothing is expected today.", "On leave")
        case .sick:
            return ("You are off sick.", "Nothing is expected today. Rest up.", "Off sick")
        case .holiday:
            return ("It is a holiday.", "Nothing is expected today.", "Holiday")
        case .weekend:
            return ("It is the weekend.", "Anything you log shows as a small mark, and it never counts toward your workdays.", "Weekend")
        case .firstRun:
            return ("Hello. I keep time for your work.", "Your work log lives on this Mac. A few steps and we are ready.", "Cadence, set up needed")
        case .firstSync:
            let i = d.importing ?? Import(label: "-", done: 0, total: 0)
            return (
                "Your history is coming in.",
                "Importing \(i.label): \(i.done) of \(count(i.total, "workday")) so far, each marked as backfilled. You can use Cadence while this runs.",
                "Importing history"
            )
        case .learning:
            let logged = d.countedWorkdays == 0 ? "No workdays logged yet." : "\(count(d.countedWorkdays, "workday")) logged so far."
            return (
                "Still learning your rhythm.", "\(logged) After \(learningDays), you will see your usual range.", "Cadence, \(items) logged"
            )
        case .sourceBehind:
            let b = d.behind ?? Behind(source: "A source", lastSync: "-")
            let synced = b.lastSync == "-" ? "It has not synced yet" : "Last synced at \(b.lastSync)"
            return (
                "\(b.source) is behind.", "\(items) so far. \(synced), so this count may be low.",
                "\(items) logged, \(b.source) is behind"
            )
        case .onCall:
            return ("On call today.", "Incidents get logged as they happen. \(items) so far, and your plan can wait if it needs to.", "On call")
        case .wrapUpDue:
            return (
                "Time to wrap up.", join("It is past your \(d.wrapUpReminder ?? "-") reminder.", stillOpen, "It takes under a minute."),
                "Wrap-up due"
            )
        case .nothingLogged:
            return (
                "Nothing logged today.", "That can be true, or a source may be off. You can seal it as it is, or mark today as not working.",
                "Nothing logged today"
            )
        case .planSettled:
            return ("Your plan is settled.", "Everything you planned is done or moved. Wrap up whenever you are ready.", "Plan settled")
        case .morning:
            let carried = d.carried > 0 ? "\(count(d.carried, "task")) carried from yesterday." : nil
            return (
                "\(weekdayName(d.date)) is wide open.", join(carried, "Pick what matters and the rest gets logged for you."), "Plan your day"
            )
        case .planned:
            return (
                "Your plan is set.",
                "\(count(d.planned, "task")) for today, and nothing logged yet. Merges, reviews and sessions appear as they happen.",
                "\(count(d.planned, "task")) planned"
            )
        case .inRhythm:
            let voice = d.planned > 0 ? "\(d.done) of \(d.planned) planned done, \(items) logged" : "\(items) logged"
            guard d.usualByNow != nil else { return ("Right in your rhythm.", "\(items) logged so far.", voice) }
            return ("Right in your rhythm.", join("\(items) logged, about your usual for now.", stillOpen), voice)
        case .moreThanUsual:
            return (
                "More logged than usual.", join("\(items) so far, and \(usual). That is a count, not a verdict.", stillOpen),
                "\(items) logged, more than usual"
            )
        case .fewerThanUsual:
            let ai = d.aiSessions > 0 ? ", including \(count(d.aiSessions, "Claude Code session"))" : ""
            return (
                "Fewer items logged so far.", "\(items), and \(usual). Long-running work does not show here\(ai).", "\(items) logged"
            )
        }
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    static func weekdayName(_ date: LocalDate) -> String {
        switch date.weekday {
        case .mon: "Monday"
        case .tue: "Tuesday"
        case .wed: "Wednesday"
        case .thu: "Thursday"
        case .fri: "Friday"
        case .sat: "Saturday"
        case .sun: "Sunday"
        }
    }
}

/// The copy rules of section 6.6 that a machine can check: no en or em dash, and none of the banned words.
public enum CopyRules {
    /// Whole words or phrases, matched without regard to case.
    public static let banned = ["productivity", "score", "missed", "you failed"]

    public static func allows(_ text: String) -> Bool {
        guard !text.contains("\u{2013}"), !text.contains("\u{2014}") else { return false }
        let words = text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        return !banned.contains { phrase in
            let parts = phrase.split(separator: " ").map(String.init)
            guard words.count >= parts.count else { return false }
            return (0...(words.count - parts.count)).contains { Array(words[$0..<($0 + parts.count)]) == parts }
        }
    }
}
