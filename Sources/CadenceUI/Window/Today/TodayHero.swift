// The hero (docs/SPEC.md sections 4.6, 6.1 and 6.4): the day's colour world, full bleed in a 24-point card, with the
// date and first activity, the headline on one line, the sentence with two lines reserved, Tempo on the right, and the
// rhythm band or the learning dots. Two fixed heights, with a chart and without one; compact lets the words wrap.
import CadenceCore
import SwiftUI

struct TodayHero: View {
    var input: TodayInput
    var width: TodayWidth
    var onBackToToday: () -> Void = {}
    var onCheckSources: () -> Void

    var body: some View {
        let world = input.world
        ZStack(alignment: .topLeading) {
            // The words are measured once below the band and Tempo and drawn once above them, as the prototype layers them.
            VStack(alignment: .leading, spacing: 0) {
                words.hidden()
                chart
            }
            if input.showsTempo, width != .compact { tempo }
            words
        }
        .frame(maxWidth: .infinity, minHeight: width == .compact ? nil : TodayGeometry.heroMinHeight, alignment: .topLeading)
        .background {
            ZStack {
                world.bg.color
                if input.showsStars { Stars(ink: world.ink.color) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CadenceRadius.card, style: .continuous))
        .foregroundStyle(world.ink.color)
        .tint(world.ink.color)
        .cadenceAnimation(CadenceMotion.world.animation, value: world.name)
    }

    private var side: CGFloat { width == .compact ? TodayGeometry.heroSideCompact : TodayGeometry.heroSide }

    private var words: some View {
        let story = input.story
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CadenceSpace.s8) {
                Text(input.kicker)
                    .cadenceType(CadenceType.label)
                    .lineLimit(width == .compact ? nil : 1)
                if input.past != nil { backToToday }
            }
            // The pill is taller than the label slot and overhangs it, so the hero keeps its height.
            .frame(minHeight: CadenceSize.labelSlot, maxHeight: width == .compact ? nil : CadenceSize.labelSlot, alignment: .leading)
            Text(story.headline)
                .cadenceType(width == .wide ? CadenceType.answer : CadenceType.section)
                .lineLimit(width == .compact ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, TodayGeometry.headlineMargin)
            sentence(story.sentence)
                .cadenceType(CadenceType.sentence)
                .lineLimit(width == .compact ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                // Two lines are always reserved, so the hero never changes height with the words.
                .frame(height: width == .compact ? nil : 2 * CadenceType.sentence.lineHeight, alignment: .topLeading)
                .frame(maxWidth: sentenceWidth, alignment: .leading)
                .padding(.trailing, sentenceClearance)
                .environment(\.openURL, OpenURLAction { _ in
                    onCheckSources()
                    return .handled
                })
        }
        .padding(.top, TodayGeometry.heroTop)
        .padding(.horizontal, side)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(input.heroVoice)
        .accessibilityAddTraits(.isHeader)
        .accessibilityActions {
            if input.showsCheckSources { Button("Check Sources", action: onCheckSources) }
            if input.past != nil { Button("Back to today", action: onBackToToday) }
        }
    }

    /// On an earlier day: the quiet pill that returns to the live day, as `esc` and `→` do.
    private var backToToday: some View {
        Button(action: onBackToToday) {
            Text(String(localized: "Back to today"))
                .cadenceType(CadenceType.label)
                .padding(.horizontal, CadenceSpace.s8)
                .frame(height: CadenceSize.chip)
                .background(Capsule().fill(input.world.ink.color.opacity(TodayGeometry.onWorldTint)))
        }
        .buttonStyle(RowButtonStyle(capsule: true))
        .focusEffectDisabled()
        .fixedSize()
        .help(String(localized: "Back to today (esc)"))
    }

    /// The sentence, ending with "Check Sources" when a source is behind.
    private func sentence(_ text: String) -> Text {
        guard input.showsCheckSources else { return Text(text) }
        var link = AttributedString(String(localized: "Check Sources"))
        link.link = URL(string: "cadence-today:check-sources")
        link.underlineStyle = .single
        link.inlinePresentationIntent = .stronglyEmphasized
        return Text(AttributedString(text + " ") + link)
    }

    /// The sentence keeps clear of Tempo.
    private var sentenceWidth: CGFloat? {
        switch width {
        case .wide: TodayGeometry.sentenceMaxWidth
        case .narrow, .compact: nil
        }
    }

    /// At 680 the sentence stops short of the smaller Tempo, as the prototype's `calc(100% - 128px)`.
    private var sentenceClearance: CGFloat {
        guard width == .narrow, input.showsTempo else { return 0 }
        return TodayGeometry.tempoNarrow + TodayGeometry.tempoTrailingNarrow
    }

    private var tempo: some View {
        let size = width == .wide ? TodayGeometry.tempoWide : TodayGeometry.tempoNarrow
        let trailing = width == .wide ? TodayGeometry.tempoTrailingWide : TodayGeometry.tempoTrailingNarrow
        return HStack {
            Spacer(minLength: 0)
            TempoView(input.tempo, size: size)
        }
        .padding(.top, TodayGeometry.tempoTop)
        .padding(.trailing, trailing)
    }

    @ViewBuilder private var chart: some View {
        switch input.heroChart {
        case .band:
            if let band = input.band {
                BandBlock(band: band, world: input.world, width: width, side: side, locale: input.locale)
            }
        case .learning(let done, let of, let caption):
            LearningDots(done: done, of: of, caption: caption, compact: width == .compact)
                .padding(.horizontal, side)
                .padding(.bottom, width == .compact ? TodayGeometry.heroTop : 0)
        case .none:
            Color.clear.frame(height: TodayGeometry.emptyChart)
        }
    }
}

/// The forest world's night sky on sealed days.
private struct Stars: View {
    var ink: Color

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<TodayGeometry.stars, id: \.self) { i in
                Circle()
                    .fill(ink.opacity(TodayGeometry.starOpacity))
                    .frame(width: TodayGeometry.starSize, height: TodayGeometry.starSize)
                    .position(
                        x: proxy.size.width * Double((i * 37) % 100) / 100,
                        y: proxy.size.height * TodayGeometry.starField * Double((i * 23) % 44) / 44)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Progress toward a range: one dot per workday, filled as they are logged.
private struct LearningDots: View {
    var done: Int
    var of: Int
    var caption: String
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s6) {
            dots
            Text(caption).cadenceType(CadenceType.body).fontWeight(.semibold).lineLimit(compact ? nil : 1)
        }
        .frame(minHeight: TodayGeometry.emptyChart, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(of) workdays. \(caption)")
    }

    @ViewBuilder private var dots: some View {
        let dot = ForEach(0..<of, id: \.self) { i in
            Circle()
                .fill(i < done ? AnyShapeStyle(.foreground) : AnyShapeStyle(.clear))
                .overlay(Circle().strokeBorder(.foreground, lineWidth: i < done ? 0 : TodayGeometry.learnRing))
                .frame(width: TodayGeometry.learnDot, height: TodayGeometry.learnDot)
        }
        if compact {
            WrapRow(spacing: CadenceSpace.s6) { dot }
        } else {
            HStack(spacing: CadenceSpace.s6) { dot }
        }
    }
}

/// Wraps its children onto new lines, for the compact learning dots.
struct WrapRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > maxWidth {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
