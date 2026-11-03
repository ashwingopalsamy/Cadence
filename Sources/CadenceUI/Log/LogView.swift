// The Log (docs/SPEC.md section 4.6): everything, newest first, grouped by day. Search over titles, tickets and notes,
// chips by work kind and by origin, one-line 40-point rows, and a detail with the entry's origin, every version the
// ledger holds, and Edit title and Change kind, each of which adds a version. Laid out as the approved prototype's `logView` (screens.js) and its `.logg` rules (coach.css).
import CadenceCore
import SwiftUI

/// What the Log's controls do. Empty by default, for snapshots.
struct LogHandlers {
    var search: (String) -> Void = { _ in }
    var family: (Family?) -> Void = { _ in }
    var origin: (Origin?) -> Void = { _ in }
    var clearChips: () -> Void = {}
    var clearFilters: () -> Void = {}
    var open: (String?) -> Void = { _ in }
    var loadMore: () -> Void = {}
    var edit: () -> Void = {}
    var draft: (String) -> Void = { _ in }
    var save: () -> Void = {}
    var cancel: () -> Void = {}
    var kind: (EntryKind) -> Void = { _ in }
    /// The search field has taken the cursor that ⌘F from another section asked for.
    var searchTaken: () -> Void = {}
}

/// The Log, live: reads through `LogModel` and takes discreet mode from `AppState`.
public struct LogView: View {
    let model: LogModel
    let app: AppState
    let navigation: WindowNavigation?

    public init(model: LogModel, app: AppState, navigation: WindowNavigation? = nil) {
        self.model = model
        self.app = app
        self.navigation = navigation
    }

    public var body: some View {
        // ⌘F from another section opens the Log with a search pending: the screen takes it when it shows, and when it
        // is asked for while the Log is already showing.
        LogScreen(
            state: LogScreen.Input(model), discreet: app.discreet, searchRequested: navigation?.searchPending ?? false,
            handlers: handlers
        )
        .onAppear { model.start() }
    }

    private var handlers: LogHandlers {
        let (model, app, navigation) = (model, app, navigation)
        return LogHandlers(
            search: { model.setSearch($0) }, family: { model.setFamily($0) }, origin: { model.setOrigin($0) },
            clearChips: { model.clearChips() }, clearFilters: { model.clearFilters() }, open: { model.open($0) },
            loadMore: { model.loadMore() }, edit: { model.beginEdit() }, draft: { model.setDraft($0) },
            save: { Task { await model.saveEdit(through: app) } }, cancel: { model.cancelEdit() },
            kind: { kind in Task { await model.changeKind(kind, through: app) } },
            searchTaken: { navigation?.takeSearch() })
    }
}

/// The Log drawn from a state. Public so the snapshot sheet can draw it from a store it read itself.
public struct LogScreen: View {
    public struct Input: Sendable, Equatable {
        public var entries: [Entry]
        public var today: LocalDate
        public var zone: TimeZone
        public var filter: LogFilter
        public var searchText: String
        public var phase: LogModel.Phase
        public var hasMore: Bool
        public var opened: LogModel.Opened?
        /// The open entry's title as a field, while it is being edited.
        public var edit: TitleEdit?
        public var kindProblem: String?
        public var saving: Bool

        public init(
            entries: [Entry], today: LocalDate, zone: TimeZone, filter: LogFilter = LogFilter(), searchText: String? = nil,
            phase: LogModel.Phase = .loaded, hasMore: Bool = false, opened: LogModel.Opened? = nil, edit: TitleEdit? = nil,
            kindProblem: String? = nil, saving: Bool = false
        ) {
            self.entries = entries
            self.today = today
            self.zone = zone
            self.filter = filter
            self.searchText = searchText ?? filter.search
            self.phase = phase
            self.hasMore = hasMore
            self.opened = opened
            self.edit = edit
            self.kindProblem = kindProblem
            self.saving = saving
        }

        @MainActor init(_ model: LogModel) {
            self.init(
                entries: model.entries, today: model.today ?? LogPage.latestDay, zone: model.zone, filter: model.filter,
                searchText: model.searchText, phase: model.phase, hasMore: model.hasMore, opened: model.opened,
                edit: model.edit, kindProblem: model.kindProblem, saving: model.saving)
        }
    }

    let state: Input
    let discreet: Bool
    let locale: Locale
    /// ⌘F was pressed in another section: the search field takes the cursor, then says so through the handlers.
    let searchRequested: Bool
    let handlers: LogHandlers

    @State private var width: CGFloat = 0
    @FocusState private var searchFocused: Bool

    /// A Log that does nothing when used: for snapshots.
    public init(state: Input, discreet: Bool, locale: Locale = .current) {
        self.init(state: state, discreet: discreet, locale: locale, handlers: LogHandlers())
    }

    init(state: Input, discreet: Bool, locale: Locale = .current, searchRequested: Bool = false, handlers: LogHandlers) {
        self.state = state
        self.discreet = discreet
        self.locale = locale
        self.searchRequested = searchRequested
        self.handlers = handlers
    }

    private var content: LogContent { LogContent(entries: state.entries, today: state.today, discreet: discreet, locale: locale) }

    private var detail: LogDetail? {
        state.opened.map { LogDetail(entry: $0.entry, events: $0.events, zone: state.zone, index: $0.index, discreet: discreet, locale: locale) }
    }

    /// Below the compact width the detail takes the list's place instead of sitting beside it (section 6.4).
    private var compact: Bool { width > 0 && width < CadenceSize.compactWidth }

    public var body: some View {
        let content = content
        let detail = detail
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(label: String(localized: "Log"), title: LogContent.title) { searchField }
                .padding(.bottom, CadenceSpace.s12)
            filters
                .padding(.bottom, CadenceSpace.s12)
            HStack(alignment: .top, spacing: CadenceSpace.s12) {
                if !(compact && detail != nil) { list(content) }
                if let detail {
                    LogDetailCard(
                        detail: detail, kind: state.opened?.entry.kind, edit: state.edit, kindProblem: state.kindProblem,
                        saving: state.saving, discreet: discreet, handlers: handlers)
                        .frame(width: compact ? nil : ListMetrics.detailWidth)
                        .frame(maxWidth: compact ? .infinity : nil)
                        .transition(.opacity)
                }
            }
            .cadenceAnimation(CadenceMotion.open.animation, value: detail?.id)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onExitCommand {
            if state.edit != nil {
                handlers.cancel()
            } else if state.opened != nil {
                handlers.open(nil)
            }
        }
        .background {
            Button("Search the log") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
        .onChange(of: searchRequested, initial: true) { _, requested in
            guard requested else { return }
            // The field is drawn in this same pass, so the cursor goes in on the next turn of the main loop.
            Task { @MainActor in
                searchFocused = true
                handlers.searchTaken()
            }
        }
    }

    // MARK: search and filters

    private var searchField: some View {
        HStack(spacing: CadenceSpace.s8) {
            Image(systemName: "magnifyingglass")
                .cadenceIcon(size: CadenceIcon.small)
                .foregroundStyle(CadenceColor.ink2.color)
                .accessibilityHidden(true)
            TextField(
                "", text: Binding(get: { state.searchText }, set: { handlers.search($0) }),
                prompt: Text(LogContent.searchPrompt).foregroundStyle(CadenceColor.ink3.color)
            )
            .textFieldStyle(.plain)
            .cadenceType(CadenceType.body)
            .foregroundStyle(CadenceColor.ink.color)
            .focused($searchFocused)
            .accessibilityLabel("Search titles, tickets and notes")
        }
        .padding(.horizontal, CadenceSpace.s12)
        .frame(width: compact ? nil : ListMetrics.searchWidth, height: CadenceSize.controlSecondary)
        .frame(maxWidth: compact ? .infinity : nil)
        .background(Capsule().fill(CadenceColor.track.color))
        .overlay(Capsule().strokeBorder(searchFocused ? CadenceColor.focus.color : Color.clear, lineWidth: ListMetrics.focusRing))
    }

    private var filters: some View {
        let filter = state.filter
        return FlowLayout(spacing: CadenceSpace.s4) {
            Button(LogContent.all) { handlers.clearChips() }
                .buttonStyle(FilterChipStyle(isOn: filter.family == nil && filter.origin == nil))
                .accessibilityAddTraits(filter.family == nil && filter.origin == nil ? .isSelected : [])
            ForEach(LogFilter.families, id: \.self) { family in
                let on = filter.family == family
                Button {
                    handlers.family(on ? nil : family)
                } label: {
                    HStack(spacing: CadenceSpace.s6) {
                        FamilyDot(family: family)
                        Text(EntryWords.family(family))
                    }
                }
                .buttonStyle(FilterChipStyle(isOn: on))
                .accessibilityLabel(EntryWords.family(family))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Rectangle()
                .fill(CadenceColor.line.color)
                .frame(width: CadenceStroke.hair, height: CadenceSpace.s16)
                .padding(.horizontal, CadenceSpace.s4)
                .frame(height: CadenceSize.controlToolbar)
                .accessibilityHidden(true)
            ForEach(LogFilter.origins, id: \.self) { origin in
                let on = filter.origin == origin
                Button(EntryWords.originChip(origin)) { handlers.origin(on ? nil : origin) }
                    .buttonStyle(FilterChipStyle(isOn: on))
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    // MARK: the list

    @ViewBuilder private func list(_ content: LogContent) -> some View {
        if case .failed(let failure) = state.phase {
            ListEmptyState(title: failure.summary, line: String(localized: "Nothing has been changed.")) { EmptyView() } action: { EmptyView() }
        } else if content.days.isEmpty, state.phase == .loaded {
            if state.filter.isClear {
                ListEmptyState(title: LogContent.nothingLogged, line: LogContent.nothingLoggedHint) { EmptyView() } action: { EmptyView() }
            } else {
                ListEmptyState(title: LogContent.nothingMatches, line: LogContent.nothingMatchesHint) {
                    EmptyView()
                } action: {
                    Button(LogContent.clearFilters) { handlers.clearFilters() }
                        .buttonStyle(WindowButtonStyle(kind: .quiet))
                        .focusEffectDisabled()
                        .padding(.top, CadenceSpace.s4)
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(content.days.enumerated()), id: \.element.id) { offset, day in
                        Text(day.title)
                            .cadenceType(ListType.dayHead)
                            .foregroundStyle(CadenceColor.ink.color)
                            .padding(.top, offset == 0 ? 0 : CadenceSpace.s12)
                            .padding(.bottom, CadenceSpace.s4)
                            .accessibilityAddTraits(.isHeader)
                        LogDayRows(rows: day.rows, opened: state.opened?.entry.id, open: handlers.open)
                    }
                    if state.hasMore {
                        Color.clear
                            .frame(height: CadenceSize.taskRow)
                            .onAppear { handlers.loadMore() }
                            .accessibilityHidden(true)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .onMoveCommand { direction in move(direction, in: content) }
        }
    }

    /// `↑` and `↓` step the open entry through the list.
    private func move(_ direction: MoveCommandDirection, in content: LogContent) {
        let ids = content.days.flatMap { $0.rows.map(\.id) }
        guard !ids.isEmpty else { return }
        let step: Int
        switch direction {
        case .up: step = -1
        case .down: step = 1
        default: return
        }
        let current = state.opened.flatMap { ids.firstIndex(of: $0.entry.id) }
        let next = current.map { min(max($0 + step, 0), ids.count - 1) } ?? 0
        handlers.open(ids[next])
    }
}

/// One day's rows: a run of 40-point rows on `card`, ruled by `line`, with the inner-control corner.
private struct LogDayRows: View {
    let rows: [LogContent.Row]
    let opened: String?
    let open: (String?) -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                let isOpen = opened == row.id
                Button {
                    open(isOpen ? nil : row.id)
                } label: {
                    LogRowLabel(row: row)
                }
                .buttonStyle(LogRowStyle(isOpen: isOpen))
                .focusEffectDisabled()
                .accessibilityLabel(row.spoken)
                .accessibilityAddTraits(isOpen ? .isSelected : [])
                .accessibilityHint(isOpen ? String(localized: "Closes its history") : String(localized: "Opens its history"))
                if offset < rows.count - 1 {
                    Rectangle()
                        .fill(contrast == .increased ? CadenceColor.ink3.color : CadenceColor.line.color)
                        .frame(height: CadenceStroke.hair)
                        .accessibilityHidden(true)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ListMetrics.groupRadius, style: .continuous))
    }
}

/// Time, work colour, title, After wrap-up, ticket, origin: always one line.
private struct LogRowLabel: View {
    let row: LogContent.Row
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColour

    var body: some View {
        HStack(spacing: CadenceSpace.s8) {
            Text(row.time)
                .cadenceType(CadenceType.figure)
                .foregroundStyle(CadenceColor.ink3.color)
                .lineLimit(1)
                .frame(minWidth: CadenceSpace.s40, alignment: .leading)
                .fixedSize()
            FamilyDot(family: row.family)
            if withoutColour {
                Text(EntryWords.family(row.family))
                    .cadenceType(CadenceType.label)
                    .foregroundStyle(CadenceColor.ink3.color)
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(spacing: CadenceSpace.s6) {
                Text(row.title)
                    .cadenceType(CadenceType.body)
                    .foregroundStyle(CadenceColor.ink.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if row.afterWrapUp { AfterWrapUpMark() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let ticket = row.ticket { LogTicketChip(key: ticket) }
            OriginBadge(origin: row.origin)
        }
    }
}

private struct LogRowStyle: ButtonStyle {
    let isOpen: Bool

    func makeBody(configuration: Configuration) -> some View {
        LogRow(configuration: configuration, isOpen: isOpen)
    }
}

private struct LogRow: View {
    let configuration: ButtonStyleConfiguration
    let isOpen: Bool
    @State private var hover = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .padding(.horizontal, ListMetrics.rowInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ListMetrics.row)
            .background(tint)
            .background(CadenceColor.card.color)
            .overlay(
                RoundedRectangle(cornerRadius: ListMetrics.groupRadius, style: .continuous)
                    .strokeBorder(focused ? CadenceColor.focus.color : Color.clear, lineWidth: ListMetrics.focusRing))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .cadenceAnimation(CadenceMotion.press.animation, value: hover)
    }

    private var tint: Color {
        if isOpen { return CadenceColor.brand.color.opacity(ListMetrics.selectedTint) }
        if hover || configuration.isPressed { return CadenceColor.ink.color.opacity(ListMetrics.hoverTint) }
        return Color.clear
    }
}

/// The entry opened: its kind, title and origin, then every version with time and actor (HistoryList, section 6.5),
/// then Edit title and Change kind. Editing, the title is a field and Edit title reads Done.
struct LogDetailCard: View {
    let detail: LogDetail
    /// The entry's kind, ticked in Change kind.
    let kind: EntryKind?
    let edit: TitleEdit?
    let kindProblem: String?
    let saving: Bool
    let discreet: Bool
    let handlers: LogHandlers

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CadenceSpace.s8) {
                Text(detail.kind)
                    .cadenceType(CadenceType.label)
                    .foregroundStyle(CadenceColor.ink3.color)
                Spacer(minLength: 0)
                Button { handlers.open(nil) } label: {
                    Image(systemName: "xmark").cadenceIcon(size: CadenceIcon.small)
                }
                .buttonStyle(IconButtonStyle())
                .focusEffectDisabled()
                .accessibilityLabel(LogDetail.close)
            }
            .frame(height: CadenceSize.labelSlot)
            if let edit {
                VStack(alignment: .leading, spacing: CadenceSpace.s2) {
                    InlineTitleField(
                        text: edit.draft, type: CadenceType.claim, discreet: discreet, set: handlers.draft,
                        save: handlers.save, cancel: handlers.cancel)
                    if let problem = edit.problem { EditProblem(text: problem) }
                }
                .padding(.top, CadenceSpace.s6)
                .padding(.bottom, CadenceSpace.s2)
            } else {
                Text(detail.title)
                    .cadenceType(CadenceType.claim)
                    .foregroundStyle(CadenceColor.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, CadenceSpace.s6)
                    .padding(.bottom, CadenceSpace.s2)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(detail.origin)
                .cadenceType(CadenceType.comparison)
                .foregroundStyle(CadenceColor.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
            Text(LogDetail.historyLabel)
                .cadenceType(CadenceType.label)
                .foregroundStyle(CadenceColor.ink3.color)
                .padding(.top, CadenceSpace.s16)
                .accessibilityAddTraits(.isHeader)
            HistoryList(versions: detail.versions)
                .padding(.top, CadenceSpace.s6)
            HStack(spacing: CadenceSpace.s8) {
                if edit == nil {
                    Button(TitleEdit.editTitle, action: handlers.edit)
                        .accessibilityLabel("Edit the title of \(detail.title)")
                } else {
                    Button(TitleEdit.done, action: handlers.save)
                        .accessibilityLabel("Save the title")
                }
                kindMenu
            }
            .buttonStyle(WindowButtonStyle(kind: .choice))
            .focusEffectDisabled()
            .disabled(saving)
            .padding(.top, CadenceSpace.s8)
            if let kindProblem {
                EditProblem(text: kindProblem)
                    .padding(.top, CadenceSpace.s8)
            }
            Text(LogDetail.footnote)
                .cadenceType(CadenceType.comparison)
                .foregroundStyle(CadenceColor.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, CadenceSpace.s8)
        }
        .padding(CadenceSpace.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cadenceCard()
        .accessibilityElement(children: .contain)
    }

    /// Every kind under its work kind, each with its work colour and name; the entry's own kind is ticked.
    private var kindMenu: some View {
        Menu {
            ForEach(TitleEdit.kindsByFamily, id: \.family) { group in
                Section(EntryWords.family(group.family)) {
                    ForEach(group.kinds, id: \.self) { option in
                        Toggle(isOn: Binding(get: { option == kind }, set: { if $0 { handlers.kind(option) } })) {
                            Label {
                                Text(CaptureAdapter.kindName(option))
                            } icon: {
                                Image(nsImage: FamilyDotImage.image(group.family))
                            }
                        }
                        .accessibilityLabel("\(CaptureAdapter.kindName(option)), \(EntryWords.family(group.family))")
                    }
                }
            }
        } label: {
            Text(TitleEdit.changeKind)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(TitleEdit.changeKind)
    }
}

/// Every version of an entry, oldest first, on a rule: the time, who did what, and the title it left.
struct HistoryList: View {
    let versions: [LogDetail.Version]

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s8) {
            ForEach(versions) { version in
                VStack(alignment: .leading, spacing: 0) {
                    Text(version.time)
                        .cadenceType(CadenceType.figure)
                        .foregroundStyle(CadenceColor.ink3.color)
                    Text(version.what)
                        .cadenceType(ListType.historyStrong)
                        .foregroundStyle(CadenceColor.ink.color)
                    Text(version.title)
                        .cadenceType(ListType.history)
                        .foregroundStyle(CadenceColor.ink2.color)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.leading, CadenceSpace.s12)
        .overlay(alignment: .leading) {
            Rectangle().fill(CadenceColor.track.color).frame(width: ListMetrics.historyRule)
        }
    }
}

/// Chips that wrap onto the next line when the window is narrow.
struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let last = rows.count - 1
            rows[last].width += (rows[last].indices.isEmpty ? 0 : spacing) + size.width
            rows[last].height = max(rows[last].height, size.height)
            rows[last].indices.append(index)
        }
        return rows
    }
}
