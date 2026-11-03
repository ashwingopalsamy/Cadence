// The Inbox (docs/SPEC.md section 4.6): every proposed entry with its work colour, title, day, why it is here and its
// origin, then Edit, Dismiss and Accept, and Accept all. Edit turns the title into a field in place. Empty, Tempo sweeps up. Laid out as the approved prototype's
// `inbox` (screens.js) and its `.inboxrow` and `.empty` rules (coach.css).
import CadenceCore
import SwiftUI

/// What the Inbox's controls do. Empty by default, for snapshots.
struct InboxHandlers {
    var accept: (String) -> Void = { _ in }
    var dismiss: (String) -> Void = { _ in }
    var acceptAll: () -> Void = {}
    var edit: (String) -> Void = { _ in }
    var draft: (String) -> Void = { _ in }
    var save: () -> Void = {}
    var cancel: () -> Void = {}
}

/// The Inbox, live: reads through `InboxModel`, writes through `AppState`, and takes discreet mode and Tempo from it.
public struct InboxView: View {
    let model: InboxModel
    let app: AppState

    public init(model: InboxModel, app: AppState) {
        self.model = model
        self.app = app
    }

    public var body: some View {
        InboxScreen(
            state: InboxScreen.Input(
                entries: model.entries, today: model.today ?? app.today, phase: model.phase, working: model.working,
                edit: model.edit),
            discreet: app.discreet, showsTempo: app.showsTempo, handlers: handlers
        )
        .onAppear { model.start() }
    }

    private var handlers: InboxHandlers {
        let (model, app) = (model, app)
        return InboxHandlers(
            accept: { id in Task { await model.accept(id, through: app) } },
            dismiss: { id in Task { await model.dismiss(id, through: app) } },
            acceptAll: { Task { await model.acceptAll(through: app) } },
            edit: { model.beginEdit($0) }, draft: { model.setDraft($0) },
            save: { Task { await model.saveEdit(through: app) } }, cancel: { model.cancelEdit() })
    }
}

/// The Inbox drawn from a state. Public so the snapshot sheet can draw it from a store it read itself.
public struct InboxScreen: View {
    public struct Input: Sendable, Equatable {
        public var entries: [Entry]
        public var today: LocalDate
        public var phase: InboxModel.Phase
        public var working: Set<String>
        /// The proposal whose title is a field, and the words in it.
        public var edit: TitleEdit?

        public init(
            entries: [Entry], today: LocalDate, phase: InboxModel.Phase = .loaded, working: Set<String> = [],
            edit: TitleEdit? = nil
        ) {
            self.entries = entries
            self.today = today
            self.phase = phase
            self.working = working
            self.edit = edit
        }
    }

    private enum Metrics {
        /// Tempo with the broom, as the prototype's empty Inbox.
        static let tempo: CGFloat = CadenceSpace.s48 * 2
    }

    let state: Input
    let discreet: Bool
    let showsTempo: Bool
    let locale: Locale
    let handlers: InboxHandlers

    /// An Inbox that does nothing when used: for snapshots.
    public init(state: Input, discreet: Bool, showsTempo: Bool, locale: Locale = .current) {
        self.init(state: state, discreet: discreet, showsTempo: showsTempo, locale: locale, handlers: InboxHandlers())
    }

    init(state: Input, discreet: Bool, showsTempo: Bool, locale: Locale = .current, handlers: InboxHandlers) {
        self.state = state
        self.discreet = discreet
        self.showsTempo = showsTempo
        self.locale = locale
        self.handlers = handlers
    }

    public var body: some View {
        let content = InboxContent(entries: state.entries, today: state.today, discreet: discreet, locale: locale)
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(label: InboxContent.label, title: headline(content)) {
                if !content.rows.isEmpty {
                    Button(InboxContent.acceptAll, action: handlers.acceptAll)
                        .buttonStyle(WindowButtonStyle(kind: .choice))
                        .focusEffectDisabled()
                        .disabled(!state.working.isEmpty)
                }
            }
            .padding(.bottom, CadenceSpace.s12)
            .accessibilityAddTraits(.updatesFrequently)
            list(content)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func headline(_ content: InboxContent) -> String {
        if case .failed(let failure) = state.phase { return failure.summary }
        return content.headline
    }

    @ViewBuilder private func list(_ content: InboxContent) -> some View {
        if case .failed = state.phase {
            ListEmptyState(title: String(localized: "Nothing has been changed."), line: String(localized: "Your proposals are kept until Cadence can read its log.")) {
                EmptyView()
            } action: {
                EmptyView()
            }
        } else if content.rows.isEmpty {
            if state.phase == .loaded {
                ListEmptyState(title: InboxContent.emptyTitle, line: InboxContent.emptyLine) {
                    if showsTempo && !discreet {
                        TempoView(TempoSpec(pose: .broom), size: Metrics.tempo)
                    }
                } action: {
                    EmptyView()
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: CadenceSpace.s12) {
                    ForEach(content.rows) { row in
                        InboxCard(
                            row: row, edit: state.edit?.entry == row.id ? state.edit : nil, discreet: discreet,
                            working: state.working.contains(row.id), handlers: handlers)
                            .transition(.opacity)
                    }
                    Text(InboxContent.footnote)
                        .cadenceType(CadenceType.comparison)
                        .foregroundStyle(CadenceColor.ink3.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .cadenceAnimation(CadenceMotion.open.animation, value: content.rows.map(\.id))
            }
            .scrollIndicators(.automatic)
        }
    }
}

/// One proposal on its card: dot, title and why, origin, then Edit, Dismiss and Accept, the primary rightmost. Editing,
/// the title is a field and Edit reads Done; a refused save says why in place of the line.
private struct InboxCard: View {
    let row: InboxContent.Row
    let edit: TitleEdit?
    let discreet: Bool
    let working: Bool
    let handlers: InboxHandlers
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColour

    var body: some View {
        HStack(spacing: CadenceSpace.s12) {
            FamilyDot(family: row.family, size: ListMetrics.familyDotLarge)
            if let edit {
                VStack(alignment: .leading, spacing: 0) {
                    InlineTitleField(
                        text: edit.draft, type: ListType.strongBody, discreet: discreet, set: handlers.draft,
                        save: handlers.save, cancel: handlers.cancel)
                    if let problem = edit.problem {
                        EditProblem(text: problem)
                    } else {
                        line
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .cadenceType(ListType.strongBody)
                        .foregroundStyle(CadenceColor.ink.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    line
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.spoken)
            }
            OriginBadge(origin: row.origin)
                .accessibilityHidden(true)
            HStack(spacing: CadenceSpace.s8) {
                if edit == nil {
                    Button(TitleEdit.edit) { handlers.edit(row.id) }
                        .buttonStyle(WindowButtonStyle(kind: .choice))
                        .accessibilityLabel("Edit \(row.title)")
                } else {
                    Button(TitleEdit.done, action: handlers.save)
                        .buttonStyle(WindowButtonStyle(kind: .choice))
                        .accessibilityLabel("Save the title")
                }
                Button(InboxContent.dismiss) { handlers.dismiss(row.id) }
                    .buttonStyle(WindowButtonStyle(kind: .choice))
                    .accessibilityLabel("Dismiss \(row.title)")
                Button(InboxContent.accept) { handlers.accept(row.id) }
                    .buttonStyle(WindowButtonStyle(kind: .primarySmall))
                    .accessibilityLabel("Accept \(row.title)")
            }
            .focusEffectDisabled()
            .disabled(working)
        }
        .padding(CadenceSpace.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cadenceCard()
        .accessibilityElement(children: .contain)
    }

    private var line: some View {
        Text(withoutColour ? "\(EntryWords.family(row.family)). \(row.line)" : row.line)
            .cadenceType(CadenceType.comparison)
            .foregroundStyle(CadenceColor.ink3.color)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
