// The menu-bar panel (docs/SPEC.md section 4.2): the plan first, a log field, and only the one action the day
// needs. `PanelView` reads AppState and acts through it; `PanelCard` draws a `PanelContent`, so the snapshot sheet
// and the app render the same thing.
import CadenceCore
import Observation
import SwiftUI

/// Tells the panel it was opened, so it can put the cursor back in the log field.
@MainActor @Observable
public final class PanelSession {
    public private(set) var opens = 0

    public init() {}

    public func opened() { opens += 1 }
}

extension PanelInput {
    /// The panel's input from the shared model. Its story is nil before the first read.
    @MainActor public static func from(_ app: AppState, pausedUntil: Date?) -> PanelInput {
        let context = app.context
        let zone = context.flatMap { TimeZone(identifier: $0.zone) } ?? .current
        var input = PanelInput(story: app.story, date: app.today)
        input.plan = (context?.plan ?? []).enumerated().map { index, task in
            var shown = task
            shown.title = app.title(task.title, index: index, word: String(localized: "Task"))
            return shown
        }
        input.carried = (context?.carried ?? []).enumerated().map { index, task in
            var shown = task
            shown.title = app.title(task.title, index: index, word: String(localized: "Task"))
            return shown
        }
        input.held = app.pendingTick?.task
        input.items = context?.rhythm.today ?? 0
        input.startedAt = app.state?.startedAt.map { Timestamp.clockTime($0, in: zone) }
        input.sealedAt = app.state?.sealedAt.map { Timestamp.clockTime($0, in: zone) }
        input.pausedUntil = pausedUntil.map { Timestamp.clockTime($0, in: .current) }
        input.behind = app.signals.behind
        input.reminderPassed = context?.passedReminder(at: app.now) != nil
        input.issue = app.issue?.summary
        input.showsTempo = app.showsTempo
        return input
    }
}

/// The panel in the app: reads AppState, ticks and logs through it, and hands everything else to `actions`.
public struct PanelView: View {
    private let app: AppState
    private let pause: CapturePause
    private let session: PanelSession
    private let actions: PanelActions
    private let tempo: (@MainActor (DayStory) -> AnyView)?
    private let close: @MainActor () -> Void

    /// `tempo` builds the character for the day's story; nil leaves the slot out until Tempo is wired.
    public init(
        app: AppState, pause: CapturePause, session: PanelSession, actions: PanelActions,
        tempo: (@MainActor (DayStory) -> AnyView)? = nil, close: @escaping @MainActor () -> Void
    ) {
        self.app = app
        self.pause = pause
        self.session = session
        self.actions = actions
        self.tempo = tempo
        self.close = close
    }

    public var body: some View {
        let input = PanelInput.from(app, pausedUntil: pause.until)
        let character: (@MainActor () -> AnyView)? = {
            guard let tempo, let story = input.story else { return nil }
            return { tempo(story) }
        }()
        PanelCard(content: PanelContent(input), handlers: handlers, tempo: character, opens: session.opens)
    }

    private var handlers: PanelHandlers {
        let app = app
        let pause = pause
        let actions = actions
        let close = close
        return PanelHandlers(
            tick: { id in
                if app.pendingTick?.task == id {
                    app.undoTick()
                } else if let task = app.context?.plan.first(where: { $0.id == id }) {
                    app.tick(task)
                }
            },
            undo: { app.undoTick() },
            log: { text, kind in await app.log(text, kind: kind) != nil },
            captureContext: { app.captureContext },
            discreet: { app.discreet },
            action: { action in
                close()
                actions.run(action)
            },
            note: { button in
                switch button {
                case .resume: pause.resume()
                case .sources:
                    close()
                    actions.openSettings(.sources)
                case .openCadence:
                    close()
                    actions.openWindow(.today)
                }
            },
            workingAfterAll: { Task { await app.workingAfterAll() } },
            dayOff: { off in Task { await app.declare(off) } },
            openWindow: { section in
                close()
                actions.openWindow(section)
            },
            openRecap: {
                close()
                actions.openRecap()
            },
            close: close)
    }
}

/// What the panel's controls do.
@MainActor
struct PanelHandlers {
    var tick: (String) -> Void = { _ in }
    var undo: () -> Void = {}
    /// Returns true when the line was logged. The kind is the one the person picked on the field's chip, if any.
    var log: (String, EntryKind?) async -> Bool = { _, _ in false }
    /// The parser's context, to read a line as it is typed.
    var captureContext: () -> CaptureContext = { CaptureAdapter.context(zone: .current, boundary: .standard, now: Date()) }
    var discreet: () -> Bool = { false }
    var action: (PanelAction) -> Void = { _ in }
    var note: (PanelContent.Note.Button) -> Void = { _ in }
    var workingAfterAll: () -> Void = {}
    var dayOff: (DayStory.DayOff) -> Void = { _ in }
    var openWindow: (PanelActions.Section) -> Void = { _ in }
    var openRecap: () -> Void = {}
    var close: () -> Void = {}
}

enum PanelFocus: Hashable {
    case log
    case row(String)
    case more
}

/// The panel drawn from its content. Public so the snapshot sheet can draw every state with sample data.
public struct PanelCard: View {
    let content: PanelContent
    let handlers: PanelHandlers
    let tempo: (@MainActor () -> AnyView)?
    let opens: Int
    let solid: Bool

    @State private var text = ""
    /// The kind picked on the field's chip. It stays until the field is cleared.
    @State private var picked: EntryKind?
    @State private var logged = false
    @FocusState private var focus: PanelFocus?

    /// A panel that does nothing when used: for snapshots. `solid` draws the Reduce Transparency ground.
    public init(content: PanelContent, tempo: (@MainActor () -> AnyView)? = nil, solid: Bool = false) {
        self.init(content: content, handlers: PanelHandlers(), tempo: tempo, opens: 0, solid: solid)
    }

    init(content: PanelContent, handlers: PanelHandlers, tempo: (@MainActor () -> AnyView)?, opens: Int, solid: Bool = false) {
        self.content = content
        self.handlers = handlers
        self.tempo = tempo
        self.opens = opens
        self.solid = solid
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let note = content.note { noteView(note).padding(.top, PanelMetrics.block) }
                area
                logField.padding(.top, PanelMetrics.block)
                if let action = content.action { actionButton(action).padding(.top, CadenceSpace.s8) }
            }
            .padding([.top, .horizontal], PanelMetrics.padding)
            footer
        }
        .frame(width: PanelMetrics.width, alignment: .leading)
        .modifier(PanelChrome(forceSolid: solid))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cadence panel")
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(phases: .down) { press in typeIntoLog(press) }
        .onExitCommand { handlers.close() }
        .onChange(of: opens) {
            logged = false
            focus = content.logEnabled ? .log : nil
        }
        .onChange(of: text) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { picked = nil }
        }
    }

    // MARK: header and note

    private var header: some View {
        HStack(spacing: CadenceSpace.s12) {
            if content.showsTempo, let tempo { TempoSlot(tempo) }
            VStack(alignment: .leading, spacing: 0) {
                Text(content.headline)
                    .cadenceType(PanelType.headline)
                    .foregroundStyle(CadenceColor.ink.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                Text(content.line)
                    .cadenceType(PanelType.line)
                    .foregroundStyle(CadenceColor.ink2.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: CadenceSize.panelTempo)
    }

    private func noteView(_ note: PanelContent.Note) -> some View {
        HStack(spacing: CadenceSpace.s8) {
            Text(note.text)
                .cadenceType(CadenceType.comparison)
                .foregroundStyle(CadenceColor.ink2.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(note.button.title) { handlers.note(note.button) }
                .buttonStyle(PanelTextButtonStyle(type: PanelType.smallStrong, color: CadenceColor.ink))
        }
        .padding(.leading, CadenceSpace.s12)
        .padding(.trailing, CadenceSpace.s4)
        .frame(height: PanelMetrics.note)
        .background(RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous).fill(CadenceColor.line.color))
        .accessibilityElement(children: .contain)
    }

    // MARK: plan area

    @ViewBuilder private var area: some View {
        switch content.area {
        case .plan(let rows, _, let count, _):
            sectionHead(content.area.title ?? "") { countView(count) }
            rowList(rows)
        case .carried(let rows):
            sectionHead(content.area.title ?? "") {
                Text("\(rows.count)").cadenceType(PanelType.head).foregroundStyle(CadenceColor.ink2.color)
            }
            rowList(rows)
        case .enjoy:
            emptyLine(PanelContent.enjoyText) {
                Button(PanelContent.workingAfterAll) { handlers.workingAfterAll() }
                    .buttonStyle(PanelTextButtonStyle(type: PanelType.smallStrong, color: CadenceColor.ink))
            }
        case .noPlan:
            emptyLine(PanelContent.noPlanText) { EmptyView() }
        case .none:
            EmptyView()
        }
    }

    private func sectionHead(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: CadenceSpace.s4) {
            Text(title)
                .cadenceType(PanelType.head)
                .foregroundStyle(CadenceColor.ink2.color)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing()
        }
        .frame(height: PanelMetrics.head)
        .padding(.top, PanelMetrics.block)
        .padding(.bottom, CadenceSpace.s2)
    }

    private func countView(_ count: PanelContent.Count) -> some View {
        HStack(spacing: CadenceSpace.s2) {
            Text(count.text)
                .cadenceType(PanelType.head)
                .foregroundStyle(CadenceColor.ink2.color)
                .accessibilityLabel(count.text)
                .accessibilityAddTraits(.updatesFrequently)
            if count.held {
                Button("Undo") { handlers.undo() }
                    .buttonStyle(PanelTextButtonStyle(type: PanelType.smallStrong, height: PanelMetrics.undo, color: CadenceColor.ink))
                    .padding(.trailing, -CadenceSpace.s8)
            }
        }
    }

    private func rowList(_ rows: [PanelContent.Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                PlanRow(row: row, focused: focus == .row(row.id)) { handlers.tick(row.id) }
                    .focusable(row.tickable || row.held)
                    .focused($focus, equals: .row(row.id))
                    .focusEffectDisabled()
                    .onKeyPress(.space) {
                        guard row.tickable || row.held else { return .ignored }
                        handlers.tick(row.id)
                        return .handled
                    }
            }
            if let more = content.area.moreText {
                Button(more) { handlers.openWindow(.today) }
                    .buttonStyle(PanelTextButtonStyle(height: PanelMetrics.row, fullWidth: true))
                    .focused($focus, equals: .more)
                    .focusEffectDisabled()
            }
        }
        .padding(.horizontal, -PanelMetrics.rowInset)
    }

    private func emptyLine(_ text: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: CadenceSpace.s8) {
            Text(text).cadenceType(PanelType.row).foregroundStyle(CadenceColor.ink2.color)
            Spacer(minLength: 0)
            trailing()
        }
        .frame(height: PanelMetrics.note)
        .padding(.top, PanelMetrics.block)
    }

    // MARK: log field and action

    private var logField: some View {
        HStack(spacing: CadenceSpace.s6) {
            if content.logEnabled {
                TextField(String(), text: $text, prompt: Text(placeholder).foregroundStyle(CadenceColor.ink3.color))
                    .textFieldStyle(.plain)
                    .cadenceType(PanelType.field)
                    .foregroundStyle(CadenceColor.ink.color)
                    .focused($focus, equals: .log)
                    .onSubmit(submit)
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { .handled }
                    .accessibilityLabel(PanelContent.logPlaceholder)
            } else {
                // A disabled field would grey the reason out; it is the one thing to read here.
                Text(PanelContent.logOffPlaceholder)
                    .cadenceType(PanelType.field)
                    .foregroundStyle(CadenceColor.ink2.color)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Log field off. \(PanelContent.logOffPlaceholder)")
            }
            if content.logEnabled, let line = typed {
                // Once there are words, the kind the line will save as and the link in it take the key hint's place.
                LogKindChip(line: line) { picked = $0 }
                LogLinkChip(line: line)
            } else {
                // While logging is off, the key it no longer answers fades.
                KeyHint(keys: "\u{2303}\u{2325}L").opacity(content.logEnabled ? 1 : PanelMetrics.disabled)
            }
        }
        .padding(.leading, CadenceSpace.s12)
        .padding(.trailing, CadenceSpace.s4)
        .frame(height: PanelMetrics.field)
        .background(RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous).fill(CadenceColor.line.color))
    }

    private var placeholder: String {
        logged ? PanelContent.loggedPlaceholder : PanelContent.logPlaceholder
    }

    /// What the line will save as. Nil while the field is empty, so an empty field is as it was.
    private var typed: LogLine? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : LogLine(text: text, picked: picked, context: handlers.captureContext(), discreet: handlers.discreet())
    }

    private func actionButton(_ action: PanelAction) -> some View {
        Button {
            handlers.action(action)
        } label: {
            HStack(spacing: CadenceSpace.s4) {
                Text(action.title).cadenceType(PanelType.action).lineLimit(1)
                Spacer(minLength: 0)
                KeyHint(keys: "\u{2318}\u{21A9}", inverted: true)
            }
        }
        .buttonStyle(PanelPrimaryStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityHint("Command Return")
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(CadenceColor.line.color).frame(height: CadenceStroke.hair)
            HStack(spacing: CadenceSpace.s2) {
                Button("Open Cadence") { handlers.openWindow(.today) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Insights") { handlers.openWindow(.insights) }
                Button("Recap") { handlers.openRecap() }
                Spacer(minLength: 0)
                if content.showsDayOff { dayOffMenu }
            }
            .buttonStyle(PanelTextButtonStyle(height: PanelMetrics.footer))
            .padding(.top, CadenceSpace.s8)
        }
        .padding(.horizontal, PanelMetrics.rowInset)
        .padding(.top, PanelMetrics.block)
        .padding(.bottom, PanelMetrics.rowInset)
    }

    private var dayOffMenu: some View {
        Menu {
            ForEach(StatusMenuItem.daysOff, id: \.1) { off, title in
                Button(title) { handlers.dayOff(off) }
            }
        } label: {
            Text("Day off")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Day off")
    }

    // MARK: keys and VoiceOver

    /// Rows the keyboard can reach, top to bottom, after the log field.
    private var targets: [PanelFocus] {
        guard case .plan(let rows, _, _, _) = content.area else { return [] }
        var list = rows.filter { $0.tickable || $0.held }.map { PanelFocus.row($0.id) }
        if content.area.moreText != nil { list.append(.more) }
        return list
    }

    /// ↓ goes from the log field to the first task and down the list; ↑ comes back up to the log field.
    private func move(_ step: Int) -> KeyPress.Result {
        let list = targets
        guard !list.isEmpty else { return .ignored }
        let index = focus.flatMap { list.firstIndex(of: $0) }
        switch (index, step > 0) {
        case (nil, true): focus = list[0]
        case (nil, false): return .ignored
        case (let i?, true): focus = list[min(list.count - 1, i + 1)]
        case (let i?, false): focus = i == 0 ? (content.logEnabled ? .log : nil) : list[i - 1]
        }
        return .handled
    }

    /// Typing anywhere in the panel goes to the log field.
    private func typeIntoLog(_ press: KeyPress) -> KeyPress.Result {
        guard content.logEnabled, focus != .log, press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let characters = press.characters
        guard !characters.isEmpty, characters != " ",
            characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return .ignored }
        text.append(characters)
        focus = .log
        return .handled
    }

    private func submit() {
        let line = text
        let kind = picked
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await handlers.log(line, kind) {
                if text == line {
                    text = ""
                    picked = nil
                }
                logged = true
            }
        }
    }
}
