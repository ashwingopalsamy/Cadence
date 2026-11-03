// The menu-bar panel as data (docs/SPEC.md section 4.2): what the header says, which note shows, what the plan
// area holds, the count, the log field and the one action. Pure, so every row of the panel table is tested without
// AppKit, and the snapshot sheet renders the same values the app does.
import CadenceCore
import Foundation

/// Everything the panel reads, already taken from the store and the app. Titles arrive as they may be shown, so
/// discreet mode has been applied before this point.
public struct PanelInput: Sendable, Equatable {
    /// Nil before the first read.
    public var story: DayStory?
    public var date: LocalDate
    /// The day's plan in plan order.
    public var plan: [PlanTask] = []
    /// Tasks carried in while the plan is not committed.
    public var carried: [PlanTask] = []
    /// The task whose tick waits for Undo.
    public var held: String?
    /// Items logged today (section 5.1).
    public var items = 0
    /// Local clock time of the first activity, such as "09:41".
    public var startedAt: String?
    /// Local clock time of today's seal.
    public var sealedAt: String?
    /// Local clock time capture resumes, when it was paused until a time.
    public var pausedUntil: String?
    public var behind: DayStory.Behind?
    /// A wrap-up reminder has passed today.
    public var reminderPassed = false
    /// Why the last write failed, while it stands.
    public var issue: String?
    /// Tempo shows: on in Settings and not discreet.
    public var showsTempo = true

    public init(story: DayStory?, date: LocalDate) {
        self.story = story
        self.date = date
    }
}

/// The one action the day needs, with `⌘↩` (section 4.2).
public enum PanelAction: Sendable, Equatable {
    case finishSetup
    case planDay
    case planToday
    /// Wrap up, with the planned tasks still open.
    case wrapUp(open: Int)
    case sealAsEmpty
    case lastWeekRecap
    case fix

    public var title: String {
        switch self {
        case .finishSetup: String(localized: "Finish setting up")
        case .planDay: String(localized: "Plan your day")
        case .planToday: String(localized: "Plan today")
        case .wrapUp(let open): open > 0 ? String(localized: "Wrap up, \(open) open") : String(localized: "Wrap up")
        case .sealAsEmpty: String(localized: "Seal as empty")
        case .lastWeekRecap: String(localized: "See last week's recap")
        case .fix: String(localized: "Open Cadence to fix")
        }
    }

    /// The panel table of section 4.2. `planned` is the size of the plan; `open` its tasks still open as shown.
    public static func choose(_ state: DayStory.State, planned: Int, open: Int, reminderPassed: Bool = false) -> PanelAction? {
        // A passed reminder offers Wrap up whatever outranked wrap-up due, so a learning, on-call or behind day can
        // still be closed from the panel (docs/decisions, audit of 2026-11-02).
        let canWrap: Set<DayStory.State> = [.learning, .firstSync, .sourceBehind, .onCall, .yesterdayOpen, .closedUnsealed]
        if reminderPassed, planned > 0, canWrap.contains(state) { return .wrapUp(open: open) }
        switch state {
        case .storeProblem: return .fix
        case .firstRun: return .finishSetup
        case .sealed, .editedAfterWrapUp: return .lastWeekRecap
        case .paused, .leave, .sick, .holiday, .weekend: return nil
        case .wrapUpDue, .planSettled: return .wrapUp(open: open)
        case .nothingLogged: return .sealAsEmpty
        case .yesterdayOpen: return planned == 0 ? .planToday : nil
        case .closedUnsealed, .firstSync, .learning, .sourceBehind, .onCall, .morning, .planned, .inRhythm, .moreThanUsual,
            .fewerThanUsual:
            return planned == 0 ? .planDay : nil
        }
    }
}

public struct PanelContent: Sendable, Equatable {
    /// Up to this many plan rows, then "N more in Today".
    public static let rows = 6

    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        /// The status as shown: a held tick reads as done.
        public var status: TaskStatus
        /// An open row that can be ticked now.
        public var tickable: Bool
        /// Its tick waits for Undo.
        public var held: Bool
    }

    public struct Note: Sendable, Equatable {
        public enum Button: Sendable, Equatable {
            case resume
            case sources
            case openCadence

            public var title: String {
                switch self {
                case .resume: String(localized: "Resume")
                case .sources: String(localized: "Sources")
                case .openCadence: String(localized: "Open Cadence")
                }
            }
        }

        public var text: String
        public var button: Button
    }

    public struct Count: Sendable, Equatable {
        public var done: Int
        public var planned: Int
        /// A tick waits for Undo.
        public var held: Bool

        public var text: String { held ? String(localized: "Logged, \(done) of \(planned)") : String(localized: "\(done) of \(planned)") }
    }

    public enum Area: Sendable, Equatable {
        /// The live plan, or the sealed plan read only.
        case plan(rows: [Row], more: Int, count: Count, sealed: Bool)
        case carried(rows: [Row])
        /// A day off: "Enjoy the day." with Working after all.
        case enjoy
        case noPlan
        /// Nothing, as on a store problem.
        case none

        public var title: String? {
            switch self {
            case .plan(_, _, _, let sealed): sealed ? String(localized: "Plan, sealed") : String(localized: "Today's plan")
            case .carried: String(localized: "Carried from yesterday")
            case .enjoy, .noPlan, .none: nil
            }
        }

        public var moreText: String? {
            if case .plan(_, let more, _, _) = self, more > 0 { return String(localized: "\(more) more in Today") }
            return nil
        }
    }

    public var state: DayStory.State?
    public var headline: String
    public var line: String
    public var note: Note?
    public var area: Area
    public var logEnabled: Bool
    public var action: PanelAction?
    public var showsDayOff: Bool
    public var showsTempo: Bool

    public static let enjoyText = String(localized: "Enjoy the day.")
    public static let workingAfterAll = String(localized: "Working after all")
    public static let noPlanText = String(localized: "No plan yet.")
    public static let logPlaceholder = String(localized: "Log something")
    public static let loggedPlaceholder = String(localized: "Logged. Anything else?")
    public static let logOffPlaceholder = String(localized: "Logging is off until the log is fixed")

    public init(_ input: PanelInput, locale: Locale = .current) {
        let state = input.story?.state
        let problem = state == .storeProblem
        let sealed = state == .sealed || state == .editedAfterWrapUp
        let off = state.map(Self.isOff) ?? false

        self.state = state
        headline = input.story?.headline ?? ""
        line = Self.line(input, locale: locale)
        note = Self.note(input)
        logEnabled = !problem

        let shown = input.plan.map { task in input.held == task.id ? TaskStatus.done : task.status }
        let open = shown.filter { $0 == .open }.count
        if problem {
            area = .none
        } else if !input.plan.isEmpty {
            let rows = input.plan.prefix(Self.rows).enumerated().map { index, task in
                let status = shown[index]
                return Row(
                    id: task.id, title: task.title, status: status, tickable: !sealed && status == .open,
                    held: input.held == task.id)
            }
            let count = Count(done: shown.filter { $0 == .done }.count, planned: input.plan.count, held: input.held != nil)
            area = .plan(rows: rows, more: max(0, input.plan.count - Self.rows), count: count, sealed: sealed)
        } else if off {
            area = .enjoy
        } else if !input.carried.isEmpty {
            area = .carried(rows: input.carried.prefix(Self.rows).map {
                Row(id: $0.id, title: $0.title, status: .open, tickable: false, held: false)
            })
        } else {
            area = .noPlan
        }
        action = state.flatMap { PanelAction.choose($0, planned: input.plan.count, open: open, reminderPassed: input.reminderPassed) }
        showsDayOff = state != nil && !off && !sealed && !problem
        showsTempo = input.showsTempo
    }

    /// Leave, sick, holiday and the weekend: nothing is expected.
    public static func isOff(_ state: DayStory.State) -> Bool {
        [.leave, .sick, .holiday, .weekend].contains(state)
    }

    /// The header's one short line.
    static func line(_ input: PanelInput, locale: Locale) -> String {
        let items = input.items == 1 ? String(localized: "1 item") : String(localized: "\(input.items) items")
        switch input.story?.state {
        case .storeProblem?: return String(localized: "Nothing can be saved until this is fixed.")
        case let state? where isOff(state): return String(localized: "Nothing expected today.")
        case .sealed?, .editedAfterWrapUp?: return String(localized: "Sealed at \(input.sealedAt ?? "-"), \(items) logged.")
        default:
            if let start = input.startedAt { return String(localized: "\(items) logged since \(start).") }
            return dateLine(input.date, locale: locale)
        }
    }

    /// The date in the system locale, such as "Thursday 29 Oct.".
    static func dateLine(_ date: LocalDate, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMM")
        return formatter.string(from: day) + "."
    }

    static func note(_ input: PanelInput) -> Note? {
        if let issue = input.issue {
            let words = issue.hasSuffix(".") ? String(issue.dropLast()) : issue
            let lowered = words.prefix(1).lowercased() + words.dropFirst()
            return Note(text: String(localized: "Not saved: \(lowered)."), button: .openCadence)
        }
        switch input.story?.state {
        case .paused?:
            let text = input.pausedUntil.map { String(localized: "Capture paused until \($0).") } ?? String(localized: "Capture paused.")
            return Note(text: text, button: .resume)
        case .sourceBehind?:
            guard let behind = input.behind else { return nil }
            return Note(text: String(localized: "\(behind.source) last synced at \(behind.lastSync)."), button: .sources)
        default:
            return nil
        }
    }
}
