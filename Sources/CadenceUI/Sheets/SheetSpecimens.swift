// The sheets in every step on ACME example data, for `make token-sheet`. Nothing here reads or writes a store.
import CadenceCore
import SwiftUI

@MainActor
public enum SheetSpecimens {
    static let day = LocalDate(year: 2026, month: 10, day: 29)!

    static func task(_ id: String, _ title: String, ticket: String? = nil, origin: PlanOrigin = .selfReported, status: TaskStatus = .open) -> PlanTask {
        PlanTask(
            id: id, day: day.description, position: 0, title: title,
            ticket: ticket.map { Ticket(key: $0, class: .assigned) }, origin: origin, status: status,
            plannedAt: "2026-10-29T09:41:00+05:30")
    }

    static var plan: PlanSheetModel {
        let model = PlanSheetModel(
            day: day,
            carried: [
                task("c1", "Draft the idempotency ADR", origin: .carried),
                task("c2", "Prototype webhook replay tool", ticket: "ACME-000000", origin: .carried),
            ],
            suggestions: [
                PlanSuggestion(title: "Review the proof export PR", family: .review, reason: "Review requested on GitHub"),
                PlanSuggestion(title: "Follow up on the webhook retry alert", family: .ownership, reason: "From yesterday's incident"),
            ],
            usual: UsualRange(low: 3, median: 4, high: 5, days: 20))
        model.toggle("suggested-0")
        model.draft = "Ship retry budget for capture path ACME-482913"
        model.addDraft()
        return model
    }

    static let wrapPlan = [
        task("w1", "Ship retry budget for capture path", ticket: "ACME-482913", status: .done),
        task("w2", "Review settlement batching RFC", status: .done),
        task("w3", "Pair on the flaky ledger test", status: .done),
        task("w4", "Draft the idempotency ADR"),
        task("w5", "Prototype webhook replay tool", ticket: "ACME-000000"),
    ]

    static let standup = """
        *Thu 29 Oct*
        Done
        \u{2022} Shipped retry budget for capture path (ACME-482913), PR #412 merged
        \u{2022} Reviewed settlement batching RFC
        \u{2022} Paired on the flaky ledger test
        Reviews 3 \u{00B7} PRs merged 1 \u{00B7} Claude Code 4 sessions
        Next
        \u{2022} Draft idempotency ADR (slipped: reprioritised)
        \u{2022} Prototype webhook replay tool (ACME-000000)
        Blockers: none
        """

    static func wrap(_ step: WrapUpStep, yesterday: Bool = false, counts: [WrapUpSignal: Int] = [:], preview: String? = nil) -> WrapUpFlow {
        let flow = WrapUpFlow(day: WrapUpDay(date: day, today: yesterday ? day.adding(days: 1) : day, plan: wrapPlan, items: 7))
        flow.show(step, preview: preview, counts: counts)
        return flow
    }

    static func wrapSheet(_ flow: WrapUpFlow) -> AnyView {
        AnyView(WrapUpSheet(flow: flow, titles: SheetTitles(), showsTempo: true, tempo: nil, actions: .none))
    }
}

/// Every sheet specimen on one page, two columns, each under its name.
public struct SheetGallery: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    private struct Specimen: Identifiable {
        let id: String
        let view: AnyView
    }

    @MainActor private var specimens: [Specimen] {
        [
            Specimen(
                id: "Morning plan",
                view: AnyView(
                    PlanSheet(model: SheetSpecimens.plan, titles: SheetTitles(), onStart: {}, onLater: {}, onDayOff: { _ in }))),
            Specimen(id: "Wrap-up, each open task", view: SheetSpecimens.wrapSheet(SheetSpecimens.wrap(.task(0)))),
            Specimen(id: "Wrap-up, Move to tomorrow asks why", view: SheetSpecimens.wrapSheet(SheetSpecimens.wrap(.reason(0)))),
            Specimen(
                id: "Wrap-up, anything else today",
                view: SheetSpecimens.wrapSheet(SheetSpecimens.wrap(.signals, counts: [.meetingLed: 1, .mentored: 2]))),
            Specimen(
                id: "Wrap-up, ready to close",
                view: SheetSpecimens.wrapSheet(SheetSpecimens.wrap(.ready, preview: SheetSpecimens.standup))),
            Specimen(id: "Wrap-up yesterday, inside its grace window", view: SheetSpecimens.wrapSheet(SheetSpecimens.wrap(.task(1), yesterday: true))),
            Specimen(id: "Wrap-up yesterday, ready to close", view: SheetSpecimens.wrapSheet(SheetSpecimens.wrap(.ready, yesterday: true))),
            Specimen(
                id: "Sealing, the end state",
                view: AnyView(
                    SealingView(tempo: nil, showsTempo: true, settled: true)
                        .frame(width: SheetLayout.width, height: SealingView.specimenHeight)
                        .clipShape(RoundedRectangle(cornerRadius: SheetLayout.radius, style: .continuous)))),
        ]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s24) {
            Text("Sheets, \(colorScheme == .dark ? "dark" : "light")")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
            let columns = [GridItem(.fixed(SheetLayout.width), spacing: CadenceSpace.s32, alignment: .top),
                           GridItem(.fixed(SheetLayout.width), spacing: CadenceSpace.s32, alignment: .top)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: CadenceSpace.s32) {
                ForEach(specimens) { specimen in
                    VStack(alignment: .leading, spacing: CadenceSpace.s8) {
                        Text(specimen.id)
                            .cadenceType(CadenceType.label)
                            .foregroundStyle(CadenceColor.ink3.color)
                        specimen.view
                            .shadow(
                                color: .black.opacity(CadenceShadow.floating.opacity), radius: CadenceShadow.floating.radius,
                                y: CadenceShadow.floating.y)
                    }
                }
            }
        }
        .padding(CadenceSpace.s24)
        .background(CadenceColor.canvas.color)
        .environment(\.sheetSurface, .solid)
    }
}
