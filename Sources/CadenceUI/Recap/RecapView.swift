// The Recap section's hub (docs/SPEC.md sections 4.6 and 5.5): the last full week, this month, the cycle once a start
// date is set, since your last 1:1 with a date, and earlier recaps. Each opens the story pager.
import CadenceCore
import SwiftUI

public struct RecapView: View {
    let model: RecapModel
    let discreet: Bool

    @State private var story: Recap?
    @State private var width: CGFloat = 0

    public init(model: RecapModel, discreet: Bool = false) {
        self.model = model
        self.discreet = discreet
    }

    public var body: some View {
        ZStack {
            ScrollView {
                content
                    .padding(CadenceSpace.windowContent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * CadenceSpace.windowContent } action: { width = $0 }
            if let story {
                // The story clips itself to the card, so its focus ring can sit outside on `canvas`.
                StoryView(recap: story, discreet: discreet) { close() }
                    .padding(CadenceSpace.windowContent)
                    .transition(.opacity)
            }
        }
        .cadenceAnimation(CadenceMotion.open.animation, value: story?.id)
        .background(CadenceColor.canvas.color)
        .onAppear { if model.hub == nil { model.reload() } }
    }

    private func close() { story = nil }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s12) {
            header
            if let hub = model.hub {
                cards(hub)
                earlier(hub)
                Text(hub.note)
                    .cadenceType(CadenceType.comparison)
                    .foregroundStyle(CadenceColor.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure = model.failure {
                Text(failure.summary)
                    .cadenceType(CadenceType.sentence)
                    .foregroundStyle(CadenceColor.ink2.color)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recap")
                .cadenceType(CadenceType.label)
                .foregroundStyle(CadenceColor.ink3.color)
                .frame(height: CadenceSpace.s32, alignment: .center)
            Text("Your work, told back to you.")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
                .lineLimit(width < CadenceSize.compactWidth ? nil : 1)
                .frame(minHeight: CadenceSpace.s32, alignment: .center)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: cards

    @ViewBuilder private func cards(_ hub: RecapHub) -> some View {
        let gap = CadenceSpace.s12
        let lead = weeklyCard(hub.weekly)
        let others = [AnyView(monthlyCard(hub.monthly))] + (hub.cycle.map { [AnyView(cycleCard($0))] } ?? [])
            + [AnyView(oneOnOneCard(hub))]
        if width >= RecapTokens.hubRow {
            // The lead card takes two shares, the others one each.
            let unit = (width - gap * CGFloat(others.count)) / CGFloat(others.count + 2)
            HStack(alignment: .top, spacing: gap) {
                lead.frame(width: unit * 2)
                ForEach(others.indices, id: \.self) { others[$0].frame(width: unit) }
            }
        } else if width >= CadenceSize.compactWidth {
            VStack(spacing: gap) {
                lead
                HStack(alignment: .top, spacing: gap) {
                    ForEach(others.indices, id: \.self) { others[$0].frame(maxWidth: .infinity) }
                }
            }
        } else {
            VStack(spacing: gap) {
                lead
                ForEach(others.indices, id: \.self) { others[$0] }
            }
        }
    }

    private func weeklyCard(_ recap: Recap) -> some View {
        RecapCard(world: CadenceWorld.butter, enabled: !recap.frames.isEmpty, open: { story = recap }) {
            kick(String(localized: "\(recap.name), your last full week"))
            plan(recap, numeral: RecapTokens.numeralLead, unit: RecapTokens.unitLead)
            note(recap.note)
        }
        .accessibilityLabel(cardLabel(String(localized: "\(recap.name), your last full week"), recap))
    }

    private func monthlyCard(_ recap: Recap) -> some View {
        RecapCard(world: CadenceWorld.forest, enabled: !recap.frames.isEmpty, open: { story = recap }) {
            kick(recap.title)
            plan(recap, numeral: CadenceType.numeral, unit: CadenceType.numeralUnit)
            note(recap.note)
        }
        .accessibilityLabel(cardLabel(recap.title, recap))
    }

    private func cycleCard(_ recap: Recap) -> some View {
        RecapCard(world: CadenceWorld.teal, enabled: !recap.frames.isEmpty, open: { story = recap }) {
            kick(String(localized: "\(recap.title), this cycle"))
            plan(recap, numeral: CadenceType.numeral, unit: CadenceType.numeralUnit)
            note(recap.note)
        }
        .accessibilityLabel(cardLabel(String(localized: "\(recap.title), this cycle"), recap))
    }

    private func oneOnOneCard(_ hub: RecapHub) -> some View {
        let world = CadenceWorld.plum
        let recap = hub.oneOnOne
        return VStack(alignment: .leading, spacing: CadenceSpace.s2) {
            kick(String(localized: "Since your last 1:1"))
            DatePicker(
                "On", selection: dateBinding(hub), in: ...Self.date(hub.today), displayedComponents: .date
            )
            .datePickerStyle(.field)
            .cadenceType(RecapTokens.row)
            .accessibilityLabel("Date of your last 1:1")
            .padding(.vertical, CadenceSpace.s8)
            note(recap.note)
            Spacer(minLength: CadenceSpace.s8)
            Button("Open recap") { story = recap }
                .buttonStyle(OnWorldStyle())
                .disabled(recap.frames.isEmpty)
        }
        .padding(CadenceSpace.s16)
        .frame(maxWidth: .infinity, minHeight: RecapTokens.cardHeight, alignment: .topLeading)
        .foregroundStyle(world.ink.color)
        .background(RoundedRectangle(cornerRadius: CadenceRadius.card, style: .continuous).fill(world.bg.color))
        .environment(\.colorScheme, .dark)
    }

    private func kick(_ text: String) -> some View {
        Text(text)
            .cadenceType(CadenceType.label)
            .lineLimit(1)
    }

    /// "Plan done", then the share in heavy rounded numerals, or "-" when it is unknown.
    private func plan(_ recap: Recap, numeral: TypeToken, unit: TypeToken) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Plan done")
                .cadenceType(CadenceType.sentence)
                .padding(.top, CadenceSpace.s4)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(recap.planPercent.map(String.init) ?? "-").cadenceType(numeral)
                if recap.planPercent != nil { Text("%").cadenceType(unit) }
            }
        }
    }

    @ViewBuilder private func note(_ text: String?) -> some View {
        if let text {
            Text(text)
                .cadenceType(RecapTokens.cardNote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cardLabel(_ title: String, _ recap: Recap) -> String {
        let plan = recap.planPercent.map { String(localized: "Plan done \($0)%.") } ?? String(localized: "Plan done unknown.")
        return [title + ".", plan, recap.note ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: earlier

    private func earlier(_ hub: RecapHub) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            kick(String(localized: "Earlier"))
                .foregroundStyle(CadenceColor.ink3.color)
                .padding(.bottom, CadenceSpace.s4)
            ForEach(Array(hub.earlier.enumerated()), id: \.element.id) { i, recap in
                if i > 0 { Rectangle().fill(CadenceColor.line.color).frame(height: CadenceStroke.hair) }
                Button { story = recap } label: {
                    HStack(alignment: .firstTextBaseline, spacing: CadenceSpace.s8) {
                        Text(recap.name).cadenceType(RecapTokens.row).foregroundStyle(CadenceColor.ink.color)
                        Text(recap.span).cadenceType(CadenceType.comparison).foregroundStyle(CadenceColor.ink3.color)
                        Spacer(minLength: CadenceSpace.s8)
                        Text(recap.planLine ?? recap.frames.first?.headline ?? "-")
                            .cadenceType(CadenceType.comparison)
                            .foregroundStyle(CadenceColor.ink3.color)
                            .lineLimit(1)
                    }
                    .frame(height: CadenceSize.foundRow)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(recap.frames.isEmpty)
            }
        }
        .padding(CadenceSpace.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cadenceCard()
    }

    // MARK: dates

    private func dateBinding(_ hub: RecapHub) -> Binding<Date> {
        Binding(
            get: { Self.date(hub.oneOnOneDate) },
            set: { picked in
                if let day = Self.day(picked), day != hub.oneOnOneDate { model.choose(oneOnOne: day) }
            })
    }

    /// Midday on that day in the calendar the date field uses.
    static func date(_ day: LocalDate) -> Date {
        Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? .now
    }

    static func day(_ date: Date) -> LocalDate? {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return LocalDate(year: year, month: month, day: day)
    }
}

/// A hub card on its colour world. The whole card is the button; it lifts a little on hover.
struct RecapCard<Content: View>: View {
    let world: ColorWorld
    let enabled: Bool
    let open: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: CadenceSpace.s2) { content }
                .padding(CadenceSpace.s16)
                .frame(maxWidth: .infinity, minHeight: RecapTokens.cardHeight, alignment: .topLeading)
                .foregroundStyle(world.ink.color)
                .background(RoundedRectangle(cornerRadius: CadenceRadius.card, style: .continuous).fill(world.bg.color))
                .contentShape(RoundedRectangle(cornerRadius: CadenceRadius.card, style: .continuous))
        }
        .buttonStyle(LiftStyle())
        .disabled(!enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
    }
}

/// A card that rises by 2 points on hover, at the press timing.
struct LiftStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LiftBody(configuration: configuration)
    }

    private struct LiftBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .offset(y: enabled && hovering && !configuration.isPressed ? -CadenceSpace.s2 : 0)
                .onHover { hovering = $0 }
                .cadenceAnimation(CadenceMotion.press.animation, value: hovering || configuration.isPressed)
        }
    }
}

/// A capsule on a colour world: the world's ink at a low opacity behind bold text.
struct OnWorldStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .cadenceType(RecapTokens.action)
            .padding(.horizontal, CadenceSpace.s12)
            .frame(height: CadenceSize.controlSecondary)
            .background(Capsule().fill(.foreground).opacity(configuration.isPressed ? RecapTokens.wash * 2 : RecapTokens.wash))
            .contentShape(Capsule())
    }
}
