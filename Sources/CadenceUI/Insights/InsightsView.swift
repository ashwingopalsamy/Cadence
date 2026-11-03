// The Insights section (docs/SPEC.md sections 4.6 and 5.4): a head with the range and the Week, Month and Cycle segment,
// then the chapters, each a matte card with its label, big number, claim and comparison beside its picture, and Show
// table beside it. Under 15 counted workdays the page says "Your patterns are still forming." and shows only what is
// already true. Nothing here moves, so Reduce Motion has nothing to stop.
import CadenceCore
import SwiftUI

enum InsightsType {
    /// The unit after the big number: "%", "of 20".
    static let unit = TypeToken(name: "numeral, large unit", face: .sfRounded, size: 28, lineHeight: 32, weight: 800, tracking: -0.01, sample: "%")
    /// The range segment.
    static let segment = TypeToken(name: "segment", face: .sfPro, size: 13, lineHeight: 20, weight: 600, tracking: 0, sample: "Month")
    /// Show table, Show chart.
    static let twin = TypeToken(name: "twin link", face: .sfPro, size: 12, lineHeight: 16, weight: 600, tracking: 0, sample: "Show table")
}

enum InsightsMetrics {
    /// The prototype's chapter: a 5 to 6 split, the picture at most this wide.
    static let chartMaxWidth: CGFloat = CadenceSize.sheetWidth - CadenceSpace.s48 * 2 - CadenceSpace.s24
    static let textShare: CGFloat = 5 / 11
    static let chapterMinHeight: CGFloat = CadenceSpace.s48 * 4 + CadenceSpace.s24
    static let padding = CadenceSpace.s24
    static let gap = CadenceSpace.s24
    /// Below this content width a chapter stacks its picture under its words.
    static let stackBelow: CGFloat = CadenceSpace.s48 * 16 + CadenceSpace.s32
    static let headRow = CadenceSize.controlSecondary
    static let trend = CadenceSize.chip
    static let tempo: CGFloat = CadenceSpace.s48 * 2 + CadenceSpace.s24
    static let segment = CadenceSize.controlToolbar
    static let segmentButton = CadenceSize.chip
    static let twin = CadenceSize.chip
    static let focusRing = CadenceSpace.s2
    /// A read slower than this shows skeleton lines; a faster one shows nothing in between (section 6.5).
    static let skeletonAfter: Duration = .milliseconds(100)
}

public struct InsightsView: View {
    let model: InsightsModel
    let showsStreak: Bool
    let showsTempo: Bool
    let milestones: MilestoneTracker?
    let scrolls: Bool

    @Environment(\.locale) private var locale
    @State private var tables: Set<InsightsChapter.ID> = []
    @State private var width: CGFloat = 0
    @State private var slow = false

    /// `showsStreak` is the streak setting: off hides the chapter and its milestones. `showsTempo` is false when Tempo is
    /// turned off or discreet mode is on. `scrolls` is false only for snapshots, which need the whole page.
    public init(
        model: InsightsModel, showsStreak: Bool = true, showsTempo: Bool = true, milestones: MilestoneTracker? = nil, scrolls: Bool = true
    ) {
        self.model = model
        self.showsStreak = showsStreak
        self.showsTempo = showsTempo
        self.milestones = milestones
        self.scrolls = scrolls
    }

    public var body: some View {
        Group {
            if scrolls {
                ScrollView(.vertical) { page }.scrollIndicators(.automatic)
            } else {
                page
            }
        }
        .background(CadenceColor.canvas.color)
        .task { model.refresh() }
        .task(id: model.load == .loading) {
            slow = false
            guard model.load == .loading else { return }
            try? await Task.sleep(for: InsightsMetrics.skeletonAfter)
            if !Task.isCancelled { slow = true }
        }
        .onChange(of: shownStreak, initial: true) { _, streak in
            if let streak { milestones?.reached(streak) }
        }
    }

    /// The streak on screen, when the setting shows it.
    private var shownStreak: Int? {
        guard showsStreak, case .loaded(let data) = model.load else { return nil }
        return data.streak.current
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s12) {
            content
        }
        .padding(CadenceSpace.windowContent)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @ViewBuilder private var content: some View {
        switch model.load {
        case .loading:
            head(label: String(localized: "Insights"), title: nil)
            if slow { Skeleton() }
        case .failed(let failure) where failure.kind == .missing:
            pageBody(InsightsPage(nil, showsStreak: showsStreak, locale: locale))
        case .failed:
            head(label: String(localized: "Insights"), title: String(localized: "I cannot read your log."))
            Text("Your data is still on disk and nothing has been changed.")
                .cadenceType(CadenceType.sentence)
                .foregroundStyle(CadenceColor.ink2.color)
        case .loaded(let data):
            pageBody(InsightsPage(data, showsStreak: showsStreak, locale: locale))
        }
    }

    @ViewBuilder private func pageBody(_ page: InsightsPage) -> some View {
        head(label: page.label, title: page.title)
        if let forming = page.forming {
            FormingCard(forming: forming, showsTempo: showsTempo, stacked: stacked, chartWidth: chartWidth)
        }
        ForEach(page.chapters) { chapter in
            ChapterCard(
                chapter: chapter, showsTable: tables.contains(chapter.id), stacked: stacked, chartWidth: chartWidth,
                toggle: { toggle(chapter.id) })
        }
    }

    /// Label and control on the first line, the title on the second (section 6.4).
    private func head(label: String, title: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                    .cadenceType(CadenceType.label)
                    .foregroundStyle(CadenceColor.ink3.color)
                    .lineLimit(1)
                Spacer(minLength: CadenceSpace.s12)
                RangeSegment(selected: model.range) { model.select($0) }
            }
            .frame(height: InsightsMetrics.headRow)
            Text(title ?? " ")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
                .lineLimit(compact ? nil : 1)
                .truncationMode(.tail)
                .frame(minHeight: InsightsMetrics.headRow, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHidden(title == nil)
        }
    }

    private func toggle(_ id: InsightsChapter.ID) {
        if tables.contains(id) { tables.remove(id) } else { tables.insert(id) }
    }

    private var compact: Bool { width > 0 && width < CadenceSize.compactWidth }
    private var stacked: Bool { width > 0 && width < InsightsMetrics.stackBelow }

    /// The picture's width beside the words, or the whole card when stacked.
    private var chartWidth: CGFloat {
        let inner = max(0, width - CadenceSpace.windowContent * 2 - InsightsMetrics.padding * 2)
        if stacked { return inner }
        return min(InsightsMetrics.chartMaxWidth, (inner - InsightsMetrics.gap) * (1 - InsightsMetrics.textShare))
    }
}

// MARK: - Parts

/// Week, Month and Cycle. Each is a button, so the keyboard reaches it, and the chosen one says so.
struct RangeSegment: View {
    let selected: InsightsRange
    let choose: (InsightsRange) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InsightsRange.allCases, id: \.self) { range in
                Button(range.title) { choose(range) }
                    .buttonStyle(SegmentStyle(selected: range == selected))
                    .accessibilityAddTraits(range == selected ? .isSelected : [])
            }
        }
        .padding(CadenceSpace.s2)
        .frame(height: InsightsMetrics.segment)
        .background(Capsule().fill(CadenceColor.track.color))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Range")
    }
}

private struct SegmentStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SegmentLabel(configuration: configuration, selected: selected)
    }
}

private struct SegmentLabel: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hover = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .cadenceType(InsightsType.segment)
            .foregroundStyle(selected || hover ? CadenceColor.ink.color : CadenceColor.ink2.color)
            .padding(.horizontal, CadenceSpace.s12)
            .frame(height: InsightsMetrics.segmentButton)
            .background(Capsule().fill(selected ? CadenceColor.card.color : Color.clear))
            .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: InsightsMetrics.focusRing))
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .cadenceAnimation(CadenceMotion.press.animation, value: hover)
    }
}

/// Show table and Show chart: a quiet capsule.
private struct TwinStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TwinLabel(configuration: configuration) }
}

private struct TwinLabel: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .cadenceType(InsightsType.twin)
            .foregroundStyle(hover || configuration.isPressed ? CadenceColor.ink.color : CadenceColor.ink2.color)
            .padding(.horizontal, CadenceSpace.s8)
            .frame(height: InsightsMetrics.twin)
            .background(Capsule().fill(CadenceColor.track.color))
            .overlay(Capsule().strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: InsightsMetrics.focusRing))
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .cadenceAnimation(CadenceMotion.press.animation, value: hover)
    }
}

/// The big number, its unit and the trend mark after it.
struct ChapterNumber: View {
    let number: String
    let unit: String?
    let trend: TrendDirection?

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: CadenceSpace.s4) {
            Text(number)
                .cadenceType(CadenceType.numeralLarge)
                .foregroundStyle(CadenceColor.ink.color)
            if let unit {
                Text(unit)
                    .cadenceType(InsightsType.unit)
                    .foregroundStyle(CadenceColor.ink.color)
            }
            if let trend {
                Image(systemName: trend == .up ? "arrow.up" : "arrow.down")
                    .font(.system(size: CadenceIcon.small, weight: .bold))
                    .foregroundStyle(CadenceColor.ink2.color)
                    .frame(width: InsightsMetrics.trend, height: InsightsMetrics.trend)
                    .background(Circle().fill(CadenceColor.track.color))
                    .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + CadenceSpace.s8 }
                    .padding(.leading, CadenceSpace.s4)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(number: number, unit: unit, trend: trend))
    }

    /// "84 %, rising", "-" as "unknown".
    static func spoken(number: String, unit: String?, trend: TrendDirection?) -> String {
        var text = number == ChartText.unknown ? String(localized: "Unknown") : number
        if let unit, number != ChartText.unknown { text += unit == "%" ? String(localized: " percent") : " \(unit)" }
        if let trend { text += trend == .up ? String(localized: ", rising") : String(localized: ", falling") }
        return text
    }
}

/// The words of a chapter: label, number, claim, comparison, and Show table.
private struct ChapterWords: View {
    let label: String
    let number: String
    let unit: String?
    let trend: TrendDirection?
    let claim: String
    let comparison: String?
    var twin: (title: String, action: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s4) {
            Text(label)
                .cadenceType(CadenceType.label)
                .foregroundStyle(CadenceColor.ink3.color)
                .frame(height: CadenceSize.labelSlot)
            ChapterNumber(number: number, unit: unit, trend: trend)
            Text(claim)
                .cadenceType(CadenceType.claim)
                .foregroundStyle(CadenceColor.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            Text(comparison ?? "")
                .cadenceType(CadenceType.comparison)
                .foregroundStyle(CadenceColor.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: CadenceSize.comparisonSlot, alignment: .topLeading)
                .accessibilityHidden(comparison == nil)
            if let twin {
                Button(twin.title, action: twin.action)
                    .buttonStyle(TwinStyle())
                    .padding(.top, CadenceSpace.s4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One chapter as a matte card: the words on the left, the picture or its table on the right, or below when narrow.
struct ChapterCard: View {
    let chapter: InsightsChapter
    let showsTable: Bool
    let stacked: Bool
    let chartWidth: CGFloat
    let toggle: () -> Void

    var body: some View {
        let words = ChapterWords(
            label: chapter.label, number: chapter.number, unit: chapter.unit, trend: chapter.trend, claim: chapter.claim,
            comparison: chapter.comparison,
            twin: chapter.chart == nil ? nil : (showsTable ? String(localized: "Show chart") : String(localized: "Show table"), toggle))
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: InsightsMetrics.gap) {
                    words
                    picture
                }
            } else {
                HStack(alignment: showsTable ? .top : .center, spacing: InsightsMetrics.gap) {
                    words
                    picture.frame(width: chartWidth)
                }
            }
        }
        .padding(InsightsMetrics.padding)
        .frame(maxWidth: .infinity, minHeight: InsightsMetrics.chapterMinHeight, alignment: .leading)
        .cadenceCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chapter.label)
    }

    @ViewBuilder private var picture: some View {
        if let chart = chapter.chart {
            if showsTable {
                ChartTableView(chart.figures.table)
            } else {
                ChapterChart(chart: chart)
            }
        } else if let note = chapter.note {
            Text(note)
                .cadenceType(CadenceType.comparison)
                .foregroundStyle(CadenceColor.ink3.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear.frame(height: 0)
        }
    }
}

/// The picture for a chapter.
struct ChapterChart: View {
    let chart: InsightsChapter.Chart

    var body: some View {
        switch chart {
        case .weekBars(let figures): WeekBars(figures)
        case .streak(let figures): StreakRoad(figures)
        case .calendar(let figures): ConsistencyCalendar(figures)
        case .split(let figures): SplitBar(figures)
        case .strata(let figures): Strata(figures)
        case .slips(let figures): SlipReasons(figures)
        case .dayShape(let figures): DayShapeChart(figures)
        case .tiles(let figures): CountTiles(figures)
        }
    }
}

/// "Your patterns are still forming.": how many counted workdays so far, and Tempo plotting its first dots.
private struct FormingCard: View {
    let forming: InsightsPage.Forming
    let showsTempo: Bool
    let stacked: Bool
    let chartWidth: CGFloat

    var body: some View {
        let words = ChapterWords(
            label: String(localized: "Your patterns"), number: String(forming.workdays), unit: String(localized: "of \(forming.of) workdays"), trend: nil,
            claim: InsightsPage.formingClaim, comparison: InsightsPage.formingComparison)
        Group {
            if stacked || !showsTempo {
                words
            } else {
                HStack(spacing: InsightsMetrics.gap) {
                    words
                    TempoView(TempoSpec(pose: .chart), size: InsightsMetrics.tempo)
                        .frame(width: chartWidth)
                }
            }
        }
        .padding(InsightsMetrics.padding)
        .frame(maxWidth: .infinity, minHeight: InsightsMetrics.chapterMinHeight, alignment: .leading)
        .cadenceCard()
        .accessibilityElement(children: .contain)
    }
}

/// Lines where the chapters will be, for a read past 100 ms. They hold still.
private struct Skeleton: View {
    var body: some View {
        ForEach(0..<3, id: \.self) { _ in
            VStack(alignment: .leading, spacing: CadenceSpace.s12) {
                line(width: CadenceSpace.s48 + CadenceSpace.s32, height: CadenceSize.labelSlot)
                line(width: CadenceSpace.s48 * 3, height: CadenceSize.numberSlot)
                line(width: CadenceSpace.s48 * 6, height: CadenceSize.sentenceSlot)
            }
            .padding(InsightsMetrics.padding)
            .frame(maxWidth: .infinity, minHeight: InsightsMetrics.chapterMinHeight, alignment: .topLeading)
            .cadenceCard()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Insights")
    }

    private func line(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
            .fill(CadenceColor.track.color)
            .frame(width: width, height: height)
    }
}
