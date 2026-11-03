// Today's cards (docs/SPEC.md sections 4.6 and 6.5): your plan with tickable rows and the day's action, the metric
// cards with their slots and table twins, Found today, Log something, the days-off cards, the unplanned card, the
// yesterday card and the failure card. Each card has its own VoiceOver label.
import CadenceCore
import SwiftUI

/// What Today can ask for. The window fills these in; the sheets and recaps are built elsewhere.
public struct TodayActions {
    public var tick: @MainActor (PlanTask) -> Void
    public var undo: @MainActor () -> Void
    /// A line from the log field, and the kind if the person picked one on its chip.
    public var log: @MainActor (String, EntryKind?) -> Void
    /// The parser's context, for the log field to read a line as it is typed.
    public var captureContext: @MainActor () -> CaptureContext
    public var perform: @MainActor (TodayAction) -> Void
    /// "Check Sources" opens Settings on that pane.
    public var openSettings: @MainActor (String) -> Void
    /// "See everything" opens Log.
    public var seeEverything: @MainActor () -> Void
    /// "Back to today" leaves an earlier day for the live one.
    public var backToToday: @MainActor () -> Void
    public var failure: @MainActor (FailureCopy.Action) -> Void

    public init(
        tick: @escaping @MainActor (PlanTask) -> Void = { _ in }, undo: @escaping @MainActor () -> Void = {},
        log: @escaping @MainActor (String, EntryKind?) -> Void = { _, _ in },
        captureContext: @escaping @MainActor () -> CaptureContext = { CaptureAdapter.context(zone: .current, boundary: .standard, now: Date()) },
        perform: @escaping @MainActor (TodayAction) -> Void = { _ in },
        openSettings: @escaping @MainActor (String) -> Void = { _ in }, seeEverything: @escaping @MainActor () -> Void = {},
        backToToday: @escaping @MainActor () -> Void = {}, failure: @escaping @MainActor (FailureCopy.Action) -> Void = { _ in }
    ) {
        self.tick = tick
        self.undo = undo
        self.log = log
        self.captureContext = captureContext
        self.perform = perform
        self.openSettings = openSettings
        self.seeEverything = seeEverything
        self.backToToday = backToToday
        self.failure = failure
    }

    /// Nothing happens: for snapshots.
    @MainActor public static var none: TodayActions { TodayActions() }
}

/// The day's actions, secondary first and the primary rightmost.
struct ActionButtons: View {
    var actions: [TodayAction]
    var perform: (TodayAction) -> Void

    var body: some View {
        HStack(spacing: CadenceSpace.s8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                if action == .notWorking {
                    // Leave, sick or holiday, as the panel's Day off menu offers.
                    Menu(action.title) {
                        ForEach(StatusMenuItem.daysOff, id: \.1) { off, _ in
                            Button(TodayAction.dayOff(off).title) { perform(.dayOff(off)) }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(CapsuleButtonStyle(quiet: true))
                    .focusEffectDisabled()
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    Button(action.title) { perform(action) }
                        .buttonStyle(CapsuleButtonStyle(quiet: action.isQuiet))
                        .focusEffectDisabled()
                        .keyboardShortcut(index == actions.count - 1 ? .defaultAction : nil)
                }
            }
        }
        .fixedSize()
    }
}

struct PlanCard: View {
    var input: TodayInput
    var width: TodayWidth
    var actions: TodayActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSlots(
                label: String(localized: "Your plan"), sentence: input.plan.isEmpty ? String(localized: "Nothing planned yet") : String(localized: "You've finished"),
                value: input.planValue, comparison: nil, compact: width == .compact)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(input.planVoice)
            if !input.plan.isEmpty {
                pebbles.padding(.vertical, CadenceSpace.s8)
            }
            VStack(spacing: 0) {
                let tasks = input.plan.isEmpty ? input.carried : input.plan
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Divider().overlay(CadenceColor.line.color) }
                    TaskRowView(
                        title: input.title(task.title, index: index, word: String(localized: "Task")), ticket: input.ticket(task),
                        status: input.status(of: task), note: input.plan.isEmpty ? String(localized: "Carried") : input.reason(task),
                        editable: input.day.sealedAt == nil && !input.plan.isEmpty && input.past == nil, width: width
                    ) { actions.tick(task) }
                }
            }
            Spacer(minLength: CadenceSpace.s12)
            HStack(spacing: CadenceSpace.s8) {
                ActionButtons(actions: input.actions, perform: actions.perform)
                if input.pendingTask != nil {
                    Button("Undo") { actions.undo() }
                        .buttonStyle(CapsuleButtonStyle(quiet: true, height: CadenceSize.controlSecondary))
                        .focusEffectDisabled()
                        .keyboardShortcut("z", modifiers: .command)
                }
                Spacer(minLength: 0)
            }
        }
        .todayCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your plan")
    }

    /// One pebble per task: filled when done, dashed when slipped, faint when dropped.
    private var pebbles: some View {
        HStack(spacing: CadenceSpace.s4) {
            ForEach(input.plan, id: \.id) { task in
                let status = input.status(of: task)
                Capsule()
                    .fill(Self.fill(status))
                    .overlay {
                        if status == .slipped {
                            Capsule().strokeBorder(CadenceColor.ink2.color, style: StrokeStyle(lineWidth: TodayGeometry.pebbleDash, dash: TodayGeometry.dash))
                        }
                    }
                    .frame(height: TodayGeometry.pebble)
            }
        }
        .accessibilityHidden(true)
    }

    static func fill(_ status: TaskStatus) -> Color {
        switch status {
        case .done: CadenceColor.brand.color
        case .slipped: .clear
        case .dropped: CadenceColor.ink3.color.opacity(TodayGeometry.droppedTint)
        case .open, .moved: CadenceColor.track.color
        }
    }
}

/// Label, sentence, number, comparison, then a picture with its table twin.
struct MetricCardView: View {
    var metric: TodayMetric
    var width: TodayWidth
    @State private var showsTable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSlots(
                label: metric.label, sentence: metric.sentence, value: metric.value, comparison: metric.comparison,
                compact: width == .compact)
            Group {
                if showsTable {
                    TwinTable(rows: metric.rows)
                } else {
                    picture
                }
            }
            .padding(.top, CadenceSpace.s12)
        }
        .todayCard()
        .overlay(alignment: .topTrailing) {
            if !metric.rows.isEmpty {
                TwinToggle(showsTable: $showsTable).padding(CadenceSpace.s12)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(metric.voice)
    }

    @ViewBuilder private var picture: some View {
        switch metric.picture {
        case .blocks(let family, let n):
            Blocks(family: family, count: n)
        case .span(let share):
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(CadenceColor.track.color)
                    if let share, share > 0 {
                        Capsule()
                            .fill(LinearGradient(
                                colors: [CadenceColor.fOwnership.color, CadenceColor.fInitiative.color, CadenceColor.fLeadership.color],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: proxy.size.width * share)
                            .offset(x: proxy.size.width * TodayGeometry.spanStart)
                    }
                }
            }
            .frame(height: TodayGeometry.spanBar)
            .clipShape(Capsule())
            .accessibilityHidden(true)
        case .legend(let items):
            HStack(spacing: CadenceSpace.s16) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: CadenceSpace.s6) {
                        FamilyDot(family: item.family, size: TodayGeometry.familyDot)
                        Text(item.text).cadenceType(CadenceType.body).fontWeight(.semibold).lineLimit(1)
                    }
                }
            }
            .foregroundStyle(CadenceColor.ink.color)
        }
    }
}

/// One square per item, eight to a row.
struct Blocks: View {
    var family: Family
    var count: Int

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: CadenceSpace.s4), count: TodayGeometry.blockColumns)
        LazyVGrid(columns: columns, alignment: .leading, spacing: CadenceSpace.s4) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: TodayGeometry.blockRadius, style: .continuous)
                    .fill(CadenceColor.family(family).color)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A card's table twin.
struct TwinTable: View {
    var rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: CadenceSpace.s8, verticalSpacing: CadenceSpace.s4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row[0]).foregroundStyle(CadenceColor.ink2.color)
                    Text(row.count > 1 ? row[1] : "").foregroundStyle(CadenceColor.ink.color).gridColumnAlignment(.trailing)
                }
                .cadenceType(CadenceType.comparison)
            }
        }
    }
}

struct FoundCard: View {
    var input: TodayInput
    var width: TodayWidth
    var actions: TodayActions

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s4) {
            HStack {
                CardLabel(input.foundLabel)
                Spacer(minLength: 0)
                Button("See everything") { actions.seeEverything() }
                    .buttonStyle(RowButtonStyle())
                    .focusEffectDisabled()
                    .cadenceType(CadenceType.comparison)
                    .fontWeight(.semibold)
                    .foregroundStyle(CadenceColor.ink2.color)
                    .frame(height: CadenceSize.labelSlot)
            }
            let entries = Array(input.shownFound.prefix(TodayGeometry.foundShown))
            if entries.isEmpty {
                Hint(input.past == nil ? String(localized: "Nothing yet. Merges, reviews and sessions appear here on their own.") : String(localized: "Nothing was found that day."))
                    .padding(.vertical, CadenceSpace.s6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().overlay(CadenceColor.line.color) }
                        FoundRowView(
                            time: input.time(of: entry), family: entry.family,
                            title: input.title(entry.title, index: index), late: entry.afterSeal, origin: entry.origin,
                            width: width, link: input.link(of: entry))
                    }
                }
            }
        }
        .todayCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(input.foundLabel), \(DayStoryWords.count(input.shownFound.count, String(localized: "item")))")
    }
}

struct LogCard: View {
    var label: String
    var sentence: String
    var placeholder: String
    var hint: String?
    var discreet = false
    var actions: TodayActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardLabel(label)
            Text(sentence)
                .cadenceType(CadenceType.sentence)
                .foregroundStyle(CadenceColor.ink.color)
                .padding(.top, CadenceSpace.s4)
                .padding(.bottom, CadenceSpace.s8)
            LogField(placeholder: placeholder, context: actions.captureContext, discreet: discreet, onLog: actions.log)
            if let hint { Hint(hint).padding(.top, CadenceSpace.s8) }
        }
        .todayCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

extension TodayInput {
    /// The log field's example, or what a line added after the seal becomes.
    var logPlaceholder: String {
        day.sealedAt != nil ? String(localized: "Added now, this is marked as after wrap-up") : String(localized: "Merged ACME-4821 retry fix")
    }
}

/// Days off: this week's sealed workdays.
struct WeekCard: View {
    var input: TodayInput
    var width: TodayWidth

    var body: some View {
        CardSlots(
            label: String(localized: "This week"), sentence: String(localized: "You sealed"), value: input.weekValue,
            comparison: String(localized: "Days off are never counted against you"), compact: width == .compact)
            .todayCard()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "This week. You sealed \(input.weekValue.map { "\($0.number) \($0.unit)" }.joined()). Days off are never counted against you.")
    }
}

/// Nothing planned and nothing found: carried tasks or "You have not planned today yet", a log field and the action.
struct UnplannedCard: View {
    var input: TodayInput
    var width: TodayWidth
    var actions: TodayActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(input.unplannedTitle)
                .cadenceType(CadenceType.claim)
                .foregroundStyle(CadenceColor.ink.color)
                .padding(.bottom, CadenceSpace.s4)
            ForEach(Array(input.carried.enumerated()), id: \.element.id) { index, task in
                if index > 0 { Divider().overlay(CadenceColor.line.color) }
                TaskRowView(
                    title: input.title(task.title, index: index, word: String(localized: "Task")), ticket: input.ticket(task), status: .open,
                    note: String(localized: "Carried"), editable: false, width: width, onTick: {})
            }
            let row = width == .compact
                ? AnyLayout(VStackLayout(alignment: .trailing, spacing: CadenceSpace.s8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: CadenceSpace.s8))
            // An earlier day is read only: nothing is logged into it from here.
            if input.past == nil || !input.actions.isEmpty {
                row {
                    if input.past == nil {
                        LogField(placeholder: input.logPlaceholder, context: actions.captureContext, discreet: input.discreet, onLog: actions.log)
                    }
                    ActionButtons(actions: input.actions, perform: actions.perform)
                }
                .padding(.top, CadenceSpace.s12)
            }
        }
        .todayCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(input.unplannedTitle)
    }
}

/// The last workday is still open: one card to wrap it up.
struct YesterdayCard: View {
    var name: String
    var summary: (line: String, detail: String)?
    var width: TodayWidth
    var perform: (TodayAction) -> Void

    var body: some View {
        let layout = width == .compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: CadenceSpace.s12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: CadenceSpace.s12))
        layout {
            VStack(alignment: .leading, spacing: 0) {
                Text(summary?.line ?? String(localized: "\(name) is not sealed yet"))
                    .cadenceType(CadenceType.sentence)
                    .fontWeight(.bold)
                    .foregroundStyle(CadenceColor.ink.color)
                Text(summary?.detail ?? String(localized: "Sealing takes under a minute."))
                    .cadenceType(CadenceType.comparison)
                    .foregroundStyle(CadenceColor.ink3.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ActionButtons(actions: [.wrapUpYesterday(name)], perform: perform)
        }
        .todayCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary.map { "\($0.line). \($0.detail)" } ?? String(localized: "\(name) is not sealed yet"))
    }
}

/// What happened, what is safe and what to do, with one primary action (section 4.6).
struct FailureCard: View {
    var copy: FailureCopy
    var perform: (FailureCopy.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(copy.label)
                .cadenceType(CadenceType.label)
                .foregroundStyle(copy.tone == .stop ? CadenceColor.warn.color : CadenceColor.ink3.color)
                .frame(height: CadenceSize.labelSlot, alignment: .leading)
            Text(copy.title)
                .cadenceType(CadenceType.claim)
                .foregroundStyle(CadenceColor.ink.color)
                .padding(.vertical, CadenceSpace.s4)
            Text(copy.body)
                .cadenceType(CadenceType.body)
                .foregroundStyle(CadenceColor.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, CadenceSpace.s12)
            HStack(spacing: CadenceSpace.s8) {
                Spacer(minLength: 0)
                Button(copy.secondary.title) { perform(copy.secondary) }
                    .buttonStyle(CapsuleButtonStyle(quiet: true))
                    .focusEffectDisabled()
                Button(copy.primary.title) { perform(copy.primary) }
                    .buttonStyle(CapsuleButtonStyle(quiet: false))
                    .focusEffectDisabled()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .todayCard(padding: EdgeInsets(
            top: TodayGeometry.failurePaddingV, leading: TodayGeometry.failurePaddingH,
            bottom: TodayGeometry.failurePaddingV, trailing: TodayGeometry.failurePaddingH))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(copy.title) \(copy.body)")
    }
}

/// First run, when the setup steps cannot be shown: there is no model for them while Cadence cannot find where it keeps
/// the work log.
struct FirstRunPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s4) {
            Text("Setup").cadenceType(CadenceType.claim).foregroundStyle(CadenceColor.ink.color)
            Text("Cadence could not start setup. Quit Cadence and open it again to try once more.")
                .cadenceType(CadenceType.sentence).foregroundStyle(CadenceColor.ink2.color)
        }
        .todayCard()
    }
}
