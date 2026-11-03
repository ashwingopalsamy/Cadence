// Today (docs/SPEC.md section 4.6): the hero, then the cards the day's layout calls for, at the window's width. The
// layout follows the prototype's twelve-column grid: the plan beside the metrics and Found today beside Log something
// when wide, one column at 680 and below.
import CadenceCore
import SwiftUI

/// Today laid out for one input and one content width. Pure: it draws what it is given.
public struct TodayContent: View {
    let input: TodayInput
    let contentWidth: CGFloat
    let actions: TodayActions

    /// `contentWidth` is the width inside the window's content edge.
    public init(input: TodayInput, contentWidth: CGFloat, actions: TodayActions) {
        self.input = input
        self.contentWidth = contentWidth
        self.actions = actions
    }

    /// The layout class reads the window's width, content edge included, as the prototype's container does.
    private var width: TodayWidth { TodayWidth.of(contentWidth + 2 * CadenceSpace.windowContent) }

    public var body: some View {
        VStack(alignment: .leading, spacing: TodayGeometry.gap) {
            TodayHero(input: input, width: width, onBackToToday: actions.backToToday) {
                actions.openSettings(String(localized: "Sources"))
            }
            .fixedSize(horizontal: false, vertical: true)
            switch input.layout {
            case .firstRun:
                FirstRunPlaceholder()
            case .storeProblem(let copy):
                FailureCard(copy: copy, perform: actions.failure)
            // An earlier day is read only, so it has no log field.
            case .dayOff:
                if input.past == nil {
                    pair(7, WeekCard(input: input, width: width), 5, offLog)
                } else {
                    WeekCard(input: input, width: width)
                }
            case .unplanned:
                yesterday
                UnplannedCard(input: input, width: width, actions: actions)
                if input.past == nil {
                    Hint(String(localized: "Merges, reviews and sessions appear here as they happen."))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            case .full:
                yesterday
                pair(5, PlanCard(input: input, width: width, actions: actions), 7, metrics)
                if input.past == nil {
                    pair(7, FoundCard(input: input, width: width, actions: actions), 5, logCard)
                } else {
                    FoundCard(input: input, width: width, actions: actions)
                }
            }
        }
        .frame(width: contentWidth, alignment: .topLeading)
        // Today is as tall as its cards, whatever height it is offered.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var yesterday: some View {
        if let name = input.yesterday {
            YesterdayCard(name: name, summary: input.yesterdaySummary, width: width, perform: actions.perform)
        }
    }

    private var offLog: some View {
        LogCard(
            label: String(localized: "If something came up"), sentence: String(localized: "Log it, and it is marked as a day-off entry."),
            placeholder: input.logPlaceholder, hint: nil, actions: actions)
    }

    private var logCard: some View {
        LogCard(
            label: String(localized: "Log something"), sentence: String(localized: "One line is enough."), placeholder: input.logPlaceholder,
            hint: String(localized: "From anywhere: press ⌃⌥L."), actions: actions)
    }

    /// Delivery, Reviews, Day length and Beyond the plan, two to a row except when compact.
    private var metrics: some View {
        let cards = input.metrics
        let columns = width == .compact ? 1 : 2
        let inner = width == .wide ? span(7) : contentWidth
        let cell = (inner - TodayGeometry.gap * CGFloat(columns - 1)) / CGFloat(columns)
        return VStack(spacing: TodayGeometry.gap) {
            ForEach(Array(stride(from: 0, to: cards.count, by: columns)), id: \.self) { start in
                HStack(alignment: .top, spacing: TodayGeometry.gap) {
                    ForEach(start..<min(start + columns, cards.count), id: \.self) { i in
                        MetricCardView(metric: cards[i], width: width).frame(width: cell)
                    }
                }
                // Rows share the column's height, so the metrics end where the plan ends.
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// The width of `n` of twelve columns.
    private func span(_ n: Int) -> CGFloat {
        let columns = CGFloat(TodayGeometry.columns)
        let unit = (contentWidth - TodayGeometry.gap * (columns - 1)) / columns
        return unit * CGFloat(n) + TodayGeometry.gap * CGFloat(n - 1)
    }

    /// Two cards side by side at equal height when wide; stacked otherwise.
    @ViewBuilder private func pair(_ a: Int, _ first: some View, _ b: Int, _ second: some View) -> some View {
        if width == .wide {
            HStack(alignment: .top, spacing: TodayGeometry.gap) {
                first.frame(width: span(a))
                second.frame(width: span(b))
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            first
            second
        }
    }
}

/// Today as the app holds it: the shared state, read and acted on through `AppState`. `←` and `→` step to the previous
/// or next day, never past today, and `esc` returns to today (section 4.8).
public struct TodayView: View {
    let app: AppState
    let contentWidth: CGFloat
    let actions: TodayActions
    let firstRun: FirstRunModel?
    let days: DayBrowser?
    @FocusState private var focused: Bool
    /// The page takes focus quietly when it opens; once focus has left and come back, the hero shows the ring.
    @State private var focusReturned = false

    public init(app: AppState, contentWidth: CGFloat, actions: TodayActions, firstRun: FirstRunModel? = nil, days: DayBrowser? = nil) {
        self.app = app
        self.contentWidth = contentWidth
        self.actions = actions
        self.firstRun = firstRun
        self.days = days
    }

    public var body: some View {
        page
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .environment(\.pageFocusVisible, focused && focusReturned)
            .onChange(of: focused) { _, now in if !now { focusReturned = true } }
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
            .onKeyPress(.escape) {
                guard let days, days.shown(today: app.today) != nil else { return .ignored }
                days.backToToday()
                return .handled
            }
            // The earlier day is read again whenever the live day is, which follows every change to the store.
            .onChange(of: app.model.reads) { days?.refresh() }
            .onChange(of: app.today) { _, today in days?.follow(today: today) }
            .onAppear { focused = true }
    }

    /// Steps only once the store has been read and setup is finished.
    private func step(_ by: Int) -> KeyPress.Result {
        guard let days, days.canStep, app.model.state != nil, app.signals.setupFinished else { return .ignored }
        days.step(by: by, today: app.today)
        return .handled
    }

    @ViewBuilder private var page: some View {
        if let input = TodayInput(app: app, days: days) {
            // First run takes the whole of Today until setup is finished (section 4.6).
            if case .firstRun = input.layout, let firstRun {
                FirstRunView(model: firstRun, showsTempo: input.showsTempo)
                    .frame(width: contentWidth, alignment: .topLeading)
            } else {
                TodayContent(input: input, contentWidth: contentWidth, actions: actions)
            }
        } else {
            // Nothing read yet. Reads under 100 ms show nothing rather than a spinner (section 6.5).
            Color.clear.frame(width: contentWidth, height: TodayGeometry.heroMinHeight)
        }
    }
}
