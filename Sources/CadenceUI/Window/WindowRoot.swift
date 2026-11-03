// The window (docs/SPEC.md sections 4.6 and 4.8): one toolbar with Today, Log, Insights, Recap and Proof as a
// segmented control on ⌘1 to ⌘5, an Inbox button with its count, and Settings on ⌘,. Each section is its own view in
// its own file, so later tasks replace them one by one. Every section starts at the same content edge.
import AppKit
import CadenceCore
import Observation
import SwiftUI

public enum WindowSection: String, CaseIterable, Sendable {
    case today, log, insights, recap, proof, inbox, settings

    /// The segmented control, in order. Inbox and Settings are buttons beside it.
    public static let tabs: [WindowSection] = [.today, .log, .insights, .recap, .proof]

    public var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .log: String(localized: "Log")
        case .insights: String(localized: "Insights")
        case .recap: String(localized: "Recap")
        case .proof: String(localized: "Proof")
        case .inbox: String(localized: "Inbox")
        case .settings: String(localized: "Settings")
        }
    }

    /// ⌘1 to ⌘5 for the tabs; ⌘, for Settings.
    public var shortcut: KeyEquivalent? {
        switch self {
        case .today: "1"
        case .log: "2"
        case .insights: "3"
        case .recap: "4"
        case .proof: "5"
        case .settings: ","
        case .inbox: nil
        }
    }
}

/// Where the window is. The panel and notifications open it to a section through this.
@MainActor @Observable
public final class WindowNavigation {
    public var section: WindowSection {
        didSet {
            // Today shows the live day again once you leave it.
            if section != .today { days.backToToday() }
            // A search nobody took does not wait for a later visit to the Log.
            if section != .log { searchPending = false }
        }
    }
    /// ⌘F was pressed outside the Log: the Log puts the cursor in its search field when it shows, and takes this.
    public private(set) var searchPending = false
    /// The Settings pane to show, such as "Sources". Nil is the first pane.
    public var settingsPane: String?
    /// The earlier day Today shows, when you step back with `←`.
    public let days: DayBrowser

    public init(section: WindowSection = .today, days: DayBrowser = DayBrowser()) {
        self.section = section
        self.days = days
    }

    public func open(_ section: WindowSection) {
        self.section = section
    }

    public func openSettings(pane: String?) {
        settingsPane = pane
        section = .settings
    }

    /// ⌘F from any section (section 4.8): the Log, with its search field to take the cursor.
    public func openSearch() {
        section = .log
        searchPending = true
    }

    /// Whether a search was waiting, which is then no longer.
    @discardableResult
    public func takeSearch() -> Bool {
        defer { searchPending = false }
        return searchPending
    }
}

/// What the window asks of the rest of the app. The plan and wrap-up sheets and recaps are built elsewhere.
public struct WindowActions {
    /// The morning plan sheet (section 4.4).
    public var openPlan: @MainActor () -> Void
    /// Today's wrap-up sheet (section 4.5).
    public var openWrapUp: @MainActor () -> Void
    /// The wrap-up sheet for the last workday, still open in its grace window.
    public var wrapUpYesterday: @MainActor () -> Void
    /// The wrap-up sheet for an earlier day that was reopened.
    public var wrapUpDay: @MainActor (LocalDate) -> Void
    /// The last full week's recap, which Today offers once the day is sealed.
    public var openRecap: @MainActor () -> Void
    /// A failure card's action other than Try again and Quit Cadence, which the window handles itself.
    public var failure: @MainActor (FailureCopy.Action) -> Void

    public init(
        openPlan: @escaping @MainActor () -> Void, openWrapUp: @escaping @MainActor () -> Void,
        wrapUpYesterday: @escaping @MainActor () -> Void, wrapUpDay: @escaping @MainActor (LocalDate) -> Void = { _ in },
        openRecap: @escaping @MainActor () -> Void, failure: @escaping @MainActor (FailureCopy.Action) -> Void
    ) {
        self.openPlan = openPlan
        self.openWrapUp = openWrapUp
        self.wrapUpYesterday = wrapUpYesterday
        self.wrapUpDay = wrapUpDay
        self.openRecap = openRecap
        self.failure = failure
    }
}

public struct WindowRoot: View {
    let app: AppState
    @Bindable var navigation: WindowNavigation
    let actions: WindowActions
    let sections: WindowSections

    public init(app: AppState, navigation: WindowNavigation, actions: WindowActions, sections: WindowSections = WindowSections()) {
        self.sections = sections
        self.app = app
        self.navigation = navigation
        self.actions = actions
    }

    public var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: CadenceSpace.s12) {
                    if let issue = app.issue {
                        IssueBanner(
                            issue: issue, canCopy: app.unsavedText != nil, copy: { actions.failure(.copyText) },
                            dismiss: { app.dismissIssue() })
                    }
                    if app.notificationsOff, !app.notificationsNoticeDismissed {
                        NotificationsOffBanner { app.notificationsNoticeDismissed = true }
                    }
                    section(contentWidth: max(0, proxy.size.width - 2 * CadenceSpace.windowContent - Self.gutter))
                }
                    .padding(CadenceSpace.windowContent)
                    .padding(.trailing, Self.gutter)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
        }
        .background(CadenceColor.canvas.color)
        .toolbar { toolbar }
        .background { shortcuts }
    }

    /// The scrollbar's width when scrollbars always show, reserved in every section whether it scrolls or not, so
    /// switching sections never moves the content edge (docs/SPEC.md, Geometry). Overlay scrollbars take no room.
    static var gutter: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    @ViewBuilder private func section(contentWidth: CGFloat) -> some View {
        switch navigation.section {
        case .today:
            TodayView(app: app, contentWidth: contentWidth, actions: todayActions, firstRun: sections.firstRun, days: navigation.days)
        case .log: LogSection(model: sections.log, app: app, navigation: navigation)
        case .insights:
            InsightsSection(
                model: sections.insights, milestones: sections.milestones, showsStreak: sections.showsStreak,
                showsTempo: app.showsTempo)
        case .recap: RecapSection(model: sections.recaps, discreet: app.discreet)
        case .proof:
            ProofSection(model: sections.proof, discreet: app.discreet, openSources: { navigation.openSettings(pane: String(localized: "Sources")) })
        case .inbox: InboxSection(model: sections.inbox, app: app)
        case .settings: SettingsSection(model: sections.settings, pane: navigation.settingsPane, showsTempo: app.showsTempo)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Section", selection: tab) {
                ForEach(WindowSection.tabs, id: \.self) { section in
                    Text(section.title).tag(Optional(section))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Today, Log, Insights, Recap and Proof: ⌘1 to ⌘5")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                navigation.open(.inbox)
            } label: {
                InboxLabel(count: app.context?.inbox)
            }
            .help("Inbox")
            .accessibilityLabel(inboxVoice)
            Button {
                navigation.openSettings(pane: nil)
            } label: {
                Image(systemName: "gearshape").cadenceIcon(size: CadenceIcon.large)
            }
            .help("Settings ⌘,")
            .accessibilityLabel("Settings")
        }
    }

    /// The segmented control shows nothing selected while Inbox or Settings is open.
    private var tab: Binding<WindowSection?> {
        Binding(
            get: { WindowSection.tabs.contains(navigation.section) ? navigation.section : nil },
            set: { if let section = $0 { navigation.open(section) } })
    }

    private var inboxVoice: String {
        guard let count = app.context?.inbox else { return String(localized: "Inbox") }
        return count == 0 ? String(localized: "Inbox, nothing to review") : String(localized: "Inbox, \(count) waiting")
    }

    /// ⌘1 to ⌘5 and ⌘,. Buttons that are present but not drawn still take their key equivalents.
    private var shortcuts: some View {
        ZStack {
            ForEach(WindowSection.allCases, id: \.self) { section in
                if let key = section.shortcut {
                    Button(section.title) {
                        section == .settings ? navigation.openSettings(pane: nil) : navigation.open(section)
                    }
                    .keyboardShortcut(key, modifiers: .command)
                }
            }
            // ⌘F searches the log and ⌘E exports a proof (section 4.8). On their own sections, the section's own
            // shortcut takes over: the search field and the Export and check button.
            if navigation.section != .log {
                Button("Search the log") { navigation.openSearch() }.keyboardShortcut("f", modifiers: .command)
            }
            if navigation.section != .proof {
                Button("Export proof") { navigation.open(.proof) }.keyboardShortcut("e", modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var todayActions: TodayActions {
        let app = app
        let navigation = navigation
        let actions = actions
        return TodayActions(
            // A task on a reopened earlier day is announced against that day's plan.
            tick: { app.tick($0, among: navigation.days.shownPlan(today: app.today)) },
            undo: { app.undoTick() },
            // A reopened earlier day takes the line onto itself; otherwise it is today's.
            log: { text, kind in
                let day = navigation.days.reopenedDay(today: app.today)
                Task { await app.log(text, kind: kind, day: day) }
            },
            captureContext: { app.captureContext },
            perform: { action in
                // An earlier day shown, reopened, is wrapped up by its own sheet; today's and yesterday's are as they were.
                let shown = navigation.days.reopenedDay(today: app.today)
                switch action {
                case .planYourDay, .planToday: actions.openPlan()
                case .wrapUp:
                    if let shown { actions.wrapUpDay(shown) } else { actions.openWrapUp() }
                case .wrapUpYesterday:
                    if let shown { actions.wrapUpDay(shown) } else { actions.wrapUpYesterday() }
                case .seeRecap: actions.openRecap()
                case .notWorking: Task { await app.declare(.leave) }
                case .dayOff(let off): Task { await app.declare(off) }
                case .sealEmpty: Task { _ = await app.seal(standup: false) }
                }
            },
            openSettings: { navigation.openSettings(pane: $0) },
            seeEverything: { navigation.open(.log) },
            backToToday: { navigation.days.backToToday() },
            // The sealed day on the page: an earlier one reached with the arrow keys, or today's.
            reopen: { [days = navigation.days] in
                let day = days.shown(today: app.today) ?? app.today
                Task { await app.reopen(day: day) }
            },
            failure: { action in
                switch action {
                case .tryAgain: app.model.reload()
                case .quit: NSApp.terminate(nil)
                default: actions.failure(action)
                }
            })
    }
}

/// The tray with its count. No badge when nothing waits, and none before the store is read.
private struct InboxLabel: View {
    var count: Int?

    var body: some View {
        Image(systemName: "tray")
            .cadenceIcon(size: CadenceIcon.large)
            .overlay(alignment: .topTrailing) {
                if let count, count > 0 {
                    Text("\(count)")
                        .cadenceType(CadenceType.label)
                        .foregroundStyle(CadenceColor.canvas.color)
                        .padding(.horizontal, CadenceSpace.s4)
                        .background(Capsule().fill(CadenceColor.ink2.color))
                        .fixedSize()
                        .offset(x: CadenceSpace.s8, y: -CadenceSpace.s6)
                }
            }
    }
}

/// What a section shows when it has no model to read, which is when Cadence could not work out where it keeps the work
/// log: its title and the one thing to do.
struct SectionPlaceholder: View {
    var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s4) {
            Text(title).cadenceType(CadenceType.section).foregroundStyle(CadenceColor.ink.color)
            Text("Cadence could not find where it keeps your work log. Quit Cadence and open it again to try once more.")
                .cadenceType(CadenceType.sentence).foregroundStyle(CadenceColor.ink2.color)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}
