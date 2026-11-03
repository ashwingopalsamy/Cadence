// The morning plan sheet (docs/SPEC.md section 4.4): "What matters today?" Carried tasks come ticked, suggestions
// wait to be picked, and typed tasks join ticked. Cadence never invents tasks, and a long plan gets a quiet note,
// not a block. "Start the day" commits through AppState with `plan.committed`.
import CadenceCore
import Observation
import SwiftUI

/// A task a collector suggests: a PR waiting to merge, a review request, a ticket touched yesterday.
public struct PlanSuggestion: Sendable, Equatable {
    public var title: String
    public var family: Family
    /// Why it is suggested, as the row says it: "Review requested on GitHub".
    public var reason: String

    public init(title: String, family: Family, reason: String) {
        self.title = title
        self.family = family
        self.reason = reason
    }
}

/// What the morning sheet holds while you pick. It writes nothing until "Start the day".
@MainActor @Observable
public final class PlanSheetModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public enum Group: Sendable { case carried, suggested, added }

        public var id: String
        public var group: Group
        public var title: String
        public var ticket: String?
        public var family: Family?
        public var note: String?
        /// The task in the store, for carried tasks and tasks added before the sheet opened.
        public var taskID: String?
    }

    /// More planned tasks than this shows the quiet note.
    public static let quietLimit = 7
    public static let quietNote = String(localized: "That is a lot for one day. You can still start, and anything open can move to tomorrow.")

    public let day: LocalDate
    /// Tasks planned per day, usually (`context.rhythm.plan`). Nil while there is no range.
    public let usual: UsualRange?
    public private(set) var rows: [Row]
    public private(set) var picked: Set<String>
    /// The add field.
    public var draft = ""
    private var typed = 0

    public init(day: LocalDate, carried: [PlanTask], suggestions: [PlanSuggestion], added: [PlanTask] = [], usual: UsualRange?) {
        self.day = day
        self.usual = usual
        var rows: [Row] = carried.map {
            Row(id: $0.id, group: .carried, title: $0.title, ticket: $0.ticket?.key, note: String(localized: "Carried"), taskID: $0.id)
        }
        rows += suggestions.enumerated().map { index, suggestion in
            Row(id: "suggested-\(index)", group: .suggested, title: suggestion.title, family: suggestion.family, note: suggestion.reason)
        }
        rows += added.map { Row(id: $0.id, group: .added, title: $0.title, ticket: $0.ticket?.key, taskID: $0.id) }
        self.rows = rows
        // Carried and added tasks start ticked; a suggestion joins only when you pick it.
        picked = Set(rows.filter { $0.group != .suggested }.map(\.id))
    }

    /// The sheet for the day the app has read, or nil while nothing has been read.
    public convenience init?(app: AppState, suggestions: [PlanSuggestion] = []) {
        guard let context = app.context else { return nil }
        self.init(
            day: app.today, carried: context.carried, suggestions: suggestions, added: context.plan,
            usual: context.rhythm.plan)
    }

    public func rows(in group: Row.Group) -> [Row] { rows.filter { $0.group == group } }

    public func isPicked(_ row: Row) -> Bool { picked.contains(row.id) }

    /// Carried and suggested rows tick and untick. Added rows are the plan already, so they stay ticked.
    public func toggle(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }), row.group != .added else { return }
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    /// Adds the typed task, ticked. False when the field is empty.
    @discardableResult
    public func addDraft() -> Bool {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        typed += 1
        rows.append(Row(id: "typed-\(typed)", group: .added, title: title))
        picked.insert("typed-\(typed)")
        draft = ""
        return true
    }

    public var planned: Int { rows.filter { picked.contains($0.id) }.count }

    public var canStart: Bool {
        planned > 0 || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "4 planned. You usually plan 3 to 5, and suggestions only join your plan if you pick them."
    public var countNote: String {
        guard let usual else { return String(localized: "\(planned) planned. Suggestions only join your plan if you pick them.") }
        let range = usual.low == usual.high ? "\(usual.low)" : String(localized: "\(usual.low) to \(usual.high)")
        return String(localized: "\(planned) planned. You usually plan \(range), and suggestions only join your plan if you pick them.")
    }

    public var showsQuietNote: Bool { planned > Self.quietLimit }

    /// What `AppState.commitPlan` gets: the picked tasks already in the store in sheet order, then the titles to add,
    /// suggestions first. Carried tasks left unticked are dropped by the commit.
    public var commitRequest: (picked: [String], added: [String]) {
        let chosen = rows.filter { picked.contains($0.id) }
        return (chosen.compactMap(\.taskID), chosen.filter { $0.taskID == nil }.map(\.title))
    }

    /// Commits the plan. A typed task still in the field joins it first. Plays `plan.committed` when it lands.
    @discardableResult
    public func commit(app: AppState, sound: CadenceSoundPlayer?) async -> Bool {
        addDraft()
        guard planned > 0 else { return false }
        let request = commitRequest
        guard await app.commitPlan(picked: request.picked, added: request.added) else { return false }
        sound?.play(.planCommitted)
        return true
    }
}

/// The morning plan sheet. The host closes it; the actions come from the host so the sheet itself stays a view.
public struct PlanSheet: View {
    @Bindable var model: PlanSheetModel
    let titles: SheetTitles
    let issue: StoreFailure?
    let onStart: () -> Void
    let onLater: () -> Void
    let onDayOff: (DayStory.DayOff) -> Void

    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColour

    public init(
        model: PlanSheetModel, titles: SheetTitles, issue: StoreFailure? = nil, onStart: @escaping () -> Void,
        onLater: @escaping () -> Void, onDayOff: @escaping (DayStory.DayOff) -> Void
    ) {
        self.model = model
        self.titles = titles
        self.issue = issue
        self.onStart = onStart
        self.onLater = onLater
        self.onDayOff = onDayOff
    }

    public var body: some View {
        SheetFrame(label: String(localized: "Plan your day")) {
            SheetKicker(SheetDate.kicker(model.day))
            SheetTitle(String(localized: "What matters today?"))
            group(.carried, label: String(localized: "Carried over"))
            group(.suggested, label: String(localized: "Suggested from your sources"))
            group(.added, label: String(localized: "Added by you"))
            addField
            Text(model.countNote)
                .cadenceType(CadenceType.comparison)
                .foregroundStyle(CadenceColor.ink3.color)
                .padding(.top, CadenceSpace.s8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            if model.showsQuietNote {
                Text(PlanSheetModel.quietNote)
                    .cadenceType(CadenceType.comparison)
                    .foregroundStyle(CadenceColor.ink2.color)
                    .padding(.top, CadenceSpace.s4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            dayOff
            SheetIssue(issue: issue)
            SheetFooter {
                Button("Later", action: onLater)
                    .buttonStyle(SheetButtonStyle(kind: .link))
                    .keyboardShortcut(.cancelAction)
            } trailing: {
                Button(action: onStart) {
                    HStack(spacing: CadenceSpace.s4) {
                        Text("Start the day")
                        KeyCap(keys: "⌘↩", inverted: true)
                    }
                }
                .buttonStyle(SheetButtonStyle(kind: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canStart)
                .accessibilityHint("Commits the plan. Command Return.")
            }
        }
    }

    // MARK: Rows

    @ViewBuilder private func group(_ group: PlanSheetModel.Row.Group, label: String) -> some View {
        let rows = model.rows(in: group)
        if !rows.isEmpty {
            Text(label)
                .cadenceType(CadenceType.label)
                .foregroundStyle(CadenceColor.ink3.color)
                .padding(.top, CadenceSpace.s12)
                .padding(.bottom, CadenceSpace.s4)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in
                pickRow(row)
            }
        }
    }

    private func pickRow(_ row: PlanSheetModel.Row) -> some View {
        let index = model.rows.firstIndex(of: row) ?? 0
        let title = titles(row.title, index: index)
        let on = model.isPicked(row)
        return Button {
            model.toggle(row.id)
        } label: {
            HStack(spacing: CadenceSpace.s8) {
                PickTick(on: on)
                if let family = row.family {
                    FamilyDot(family: family, size: SheetLayout.familyDot)
                    // Differentiate Without Colour: the kind of work says its name too (section 6.7).
                    if withoutColour {
                        Text(EntryWords.family(family))
                            .cadenceType(CadenceType.label)
                            .foregroundStyle(CadenceColor.ink3.color)
                            .lineLimit(1)
                            .fixedSize()
                    }
                } else {
                    Color.clear.frame(width: SheetLayout.familyDot, height: SheetLayout.familyDot)
                }
                Text(title)
                    .cadenceType(SheetType.row)
                    .foregroundStyle(CadenceColor.ink.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let ticket = row.ticket, !titles.discreet {
                    TicketChip(key: ticket)
                }
                if let note = row.note {
                    Text(note)
                        .cadenceType(CadenceType.comparison)
                        .foregroundStyle(CadenceColor.ink3.color)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .frame(height: SheetLayout.pickRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(PickRowStyle())
        .disabled(row.group == .added)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, row.note].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(on ? String(localized: "Picked") : String(localized: "Not picked"))
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: Add and day off

    private var addField: some View {
        HStack(spacing: CadenceSpace.s8) {
            TextField("Add a task", text: $model.draft)
                .textFieldStyle(.plain)
                .cadenceType(CadenceType.body)
                .foregroundStyle(CadenceColor.ink.color)
                .focused($fieldFocused)
                .onSubmit { model.addDraft() }
                .accessibilityLabel("Add a task")
            Button("Add") { model.addDraft() }
                .buttonStyle(AddButtonStyle())
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, CadenceSpace.s12)
        .padding([.vertical, .trailing], CadenceSpace.s4)
        .frame(height: CadenceSize.controlPrimary)
        .background(
            RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous).fill(CadenceColor.track.color)
        )
        .padding(.top, CadenceSpace.s12)
    }

    private var dayOff: some View {
        HStack(spacing: CadenceSpace.s4) {
            Text("Not working today:")
                .cadenceType(CadenceType.comparison)
                .foregroundStyle(CadenceColor.ink3.color)
                .padding(.trailing, CadenceSpace.s4)
            Button("Leave") { onDayOff(.leave) }.buttonStyle(SheetButtonStyle(kind: .small))
            Button("Sick") { onDayOff(.sick) }.buttonStyle(SheetButtonStyle(kind: .small))
            Button("Holiday") { onDayOff(.holiday) }.buttonStyle(SheetButtonStyle(kind: .small))
        }
        .padding(.top, CadenceSpace.s8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Not working today")
    }
}

/// The round tick of a pick row: a ring when open, filled ink with a check when picked.
struct PickTick: View {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(on ? Color.clear : CadenceColor.ink3.color, lineWidth: CadenceIcon.stroke(SheetLayout.tickStroke, contrast))
                .background(Circle().fill(on ? CadenceColor.ink.color : Color.clear))
            if on {
                Image(systemName: "checkmark")
                    .font(.system(size: CadenceIcon.small - CadenceSpace.s2, weight: CadenceIcon.weight(.bold, contrast)))
                    .foregroundStyle(CadenceColor.canvas.color)
            }
        }
        .frame(width: SheetLayout.tick, height: SheetLayout.tick)
        .animation(CadenceMotion.resolved(CadenceMotion.tick.animation, reduceMotion: reduceMotion), value: on)
        .accessibilityHidden(true)
    }
}

/// A ticket key in the figure face, on a small track.
struct TicketChip: View {
    let key: String

    var body: some View {
        Text(key)
            .cadenceType(CadenceType.figure)
            .foregroundStyle(CadenceColor.ink2.color)
            .padding(.horizontal, CadenceSpace.s6)
            .frame(height: CadenceSize.ticket)
            .background(RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous).fill(CadenceColor.track.color))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A whole row is the button; focus draws the ring around it.
private struct PickRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PickRowBody(configuration: configuration)
    }
}

private struct PickRowBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, CadenceSpace.s4)
            .background {
                if isFocused {
                    RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
                        .stroke(CadenceColor.focus.color, lineWidth: SheetLayout.tickStroke)
                }
            }
            .padding(.horizontal, -CadenceSpace.s4)
    }
}

/// The add field's own button: a quiet fill of ink over the track.
private struct AddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AddButtonBody(configuration: configuration)
    }
}

private struct AddButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .cadenceType(SheetType.choice)
            .foregroundStyle(CadenceColor.ink.color)
            .padding(.horizontal, CadenceSpace.s12)
            .frame(height: CadenceSize.controlSecondary)
            .background(
                RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
                    .fill(CadenceColor.ink.color.opacity(SheetLayout.addFill))
            )
            .opacity(isEnabled ? 1 : CadenceDisabled.opacity)
    }
}
