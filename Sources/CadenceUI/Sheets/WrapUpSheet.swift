// The wrap-up (docs/SPEC.md sections 4.5 and 4.8): one question at a time in one sheet with a step bar. Each open
// task gets Done (D), Move to tomorrow (M, then a reason chip) or Drop it (X); then "Anything else today?" tiles;
// then "Ready to close" with the stand-up and the seal. "Not yet" closes at any step and keeps the answers. Wrapping
// up yesterday inside its grace window uses the same sheet, without the tiles and the stand-up.
import AppKit
import CadenceCore
import Observation
import SwiftUI

/// The day being wrapped up, as read when the sheet opened.
public struct WrapUpDay: Sendable, Equatable {
    public var date: LocalDate
    /// The day the app is on. A date before it is yesterday's wrap-up, inside its grace window.
    public var today: LocalDate
    /// The day's plan in plan order.
    public var plan: [PlanTask]
    /// Items logged on the day.
    public var items: Int
    /// Tickets of the pull requests merged on the day. A task with one of them starts on Done (section 4.5).
    public var merged: Set<String>

    public init(date: LocalDate, today: LocalDate, plan: [PlanTask], items: Int, merged: Set<String> = []) {
        self.date = date
        self.today = today
        self.plan = plan
        self.items = items
        self.merged = merged
    }

    /// The day a context was read for. Nil when the context names no valid date.
    public init?(context: DayContext, today: LocalDate) {
        guard let date = LocalDate(context.view.day.date) else { return nil }
        let merged = context.view.entries.filter { $0.kind == .prMerged && $0.status == .accepted }.compactMap(\.ticket?.key)
        self.init(date: date, today: today, plan: context.plan, items: context.rhythm.today, merged: Set(merged))
    }

    public var isYesterday: Bool { date < today }
}

/// "Anything else today?" The tiles, each logged as its own kind.
public enum WrapUpSignal: String, CaseIterable, Sendable, Identifiable {
    case meetingLed, decisionChallenged, mentored, incident

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .meetingLed: String(localized: "Led a meeting")
        case .decisionChallenged: String(localized: "Challenged a decision")
        case .mentored: String(localized: "Mentored someone")
        case .incident: String(localized: "Handled an incident")
        }
    }

    public var kind: EntryKind {
        switch self {
        case .meetingLed: .meetingLed
        case .decisionChallenged: .decisionChallenged
        case .mentored: .mentoring
        case .incident: .incidentHandled
        }
    }

    public var family: Family {
        switch self {
        case .incident: .ownership
        default: .leadership
        }
    }
}

/// How one open task went.
public enum WrapUpAnswer: Sendable, Equatable {
    case done
    case moved(SlipReason)
    case dropped

    /// Moving is recorded as slipped with the chip's stored value.
    public var status: TaskStatus {
        switch self {
        case .done: .done
        case .moved: .slipped
        case .dropped: .dropped
        }
    }

    public var reason: String? {
        if case .moved(let reason) = self { return reason.rawValue }
        return nil
    }
}

public enum WrapUpStep: Sendable, Equatable {
    /// The open task at this index: "How did this one go?"
    case task(Int)
    /// The same task after Move: "What happened?"
    case reason(Int)
    case signals
    case ready
}

/// What the wrap-up writes through. `AppState` is the app's; tests and specimens may pass their own.
@MainActor public protocol WrapUpWriting: AnyObject {
    func resolve(_ task: String, as status: TaskStatus, reason: String?) async -> Bool
    /// Move to tomorrow: slipped here with its reason, carried to the next workday (section 4.5).
    func move(_ task: String, reason: SlipReason) async -> Bool
    func log(_ request: LogRequest) async -> Bool
    func seal(day: LocalDate?, standup: Bool) async -> (sealed: SealResult, standup: String?)?
}

extension AppState: WrapUpWriting {
    public func log(_ request: LogRequest) async -> Bool {
        await perform(.log(request)) != nil
    }
}

/// The wrap-up's answers and where it is. Each answer is written as it is given, so "Not yet" loses nothing; the
/// tiles are written when you continue past them, and only the counts not written yet.
@MainActor @Observable
public final class WrapUpFlow {
    public let day: WrapUpDay
    /// The tasks still open when the sheet opened, in plan order. Answers never reorder them.
    public let open: [PlanTask]
    public private(set) var step: WrapUpStep
    public private(set) var answers: [String: WrapUpAnswer] = [:]
    public private(set) var counts: [WrapUpSignal: Int] = [:]
    public private(set) var notes: [WrapUpSignal: String] = [:]
    private var logged: [WrapUpSignal: Int] = [:]
    /// The stand-up as it will read, without the witness code, which only the seal adds.
    public var preview: String?
    /// A write is on its way; the choices wait for it.
    public private(set) var busy = false
    /// Set once the seal lands; the sheet then plays the moment.
    public private(set) var sealed: SealResult?

    public static let reasonPrompt = String(localized: "What happened? This helps your patterns, and it is never judged.")
    public static let copyHint = String(localized: "A code only helps if it reaches someone else, so copying is the default.")
    public static let lateSeal = String(localized: "This will show as sealed the next morning, on your log and in any proof.")
    public static let standupLead = String(localized: "Your stand-up is ready. Sent to your team, its last line shows this log existed today.")

    public init(day: WrapUpDay) {
        self.day = day
        open = day.plan.filter { $0.status == .open }
        step = .task(0)
        if open.isEmpty { step = afterTasks }
    }

    private var afterTasks: WrapUpStep { day.isYesterday ? .ready : .signals }

    // MARK: Where we are

    /// One step per open task, then the tiles (not for yesterday), then Ready to close.
    public var stepCount: Int { open.count + (day.isYesterday ? 1 : 2) }

    public var stepIndex: Int {
        switch step {
        case .task(let index), .reason(let index): index
        case .signals: open.count
        case .ready: stepCount - 1
        }
    }

    public var current: PlanTask? {
        switch step {
        case .task(let index), .reason(let index): open.indices.contains(index) ? open[index] : nil
        default: nil
        }
    }

    /// "Its pull request for ACME-142 merged today.", when the current task's ticket merged on the day.
    public var mergedNote: String? {
        guard let key = current?.ticket?.key, day.merged.contains(key) else { return nil }
        return day.isYesterday
            ? String(localized: "Its pull request for \(key) merged \(SheetDate.weekday(day.date)).")
            : String(localized: "Its pull request for \(key) merged today.")
    }

    /// "Wrap up, 2 left" or "Wrap up Wednesday, 1 left".
    public var taskKicker: String {
        let left = open.count - stepIndex
        return day.isYesterday ? String(localized: "Wrap up \(SheetDate.weekday(day.date)), \(left) left") : String(localized: "Wrap up, \(left) left")
    }

    /// "Move to tomorrow", or the day it moves to when wrapping up yesterday: "Move to Thursday".
    public var moveLabel: String {
        day.isYesterday ? String(localized: "Move to \(SheetDate.weekday(day.today))") : String(localized: "Move to tomorrow")
    }

    public var readyKicker: String {
        day.isYesterday ? String(localized: "Ready to close \(SheetDate.weekday(day.date))") : String(localized: "Ready to close")
    }

    public var sealLabel: String { String(localized: "Seal \(SheetDate.weekday(day.date))") }

    // MARK: Tasks

    /// Opens the reason chips for the current task.
    public func move() {
        guard case .task(let index) = step, !busy else { return }
        step = .reason(index)
    }

    /// Writes the answer for the current task, then moves on. Stays put when the write fails.
    @discardableResult
    public func answer(_ answer: WrapUpAnswer, writer: any WrapUpWriting) async -> Bool {
        guard let task = current, !busy else { return false }
        busy = true
        defer { busy = false }
        if case .moved(let reason) = answer {
            guard await writer.move(task.id, reason: reason) else { return false }
        } else {
            guard await writer.resolve(task.id, as: answer.status, reason: answer.reason) else { return false }
        }
        answers[task.id] = answer
        let next = stepIndex + 1
        step = next < open.count ? .task(next) : afterTasks
        return true
    }

    // MARK: Tiles

    public func tap(_ signal: WrapUpSignal) {
        counts[signal, default: 0] += 1
    }

    /// Back to what is already written, which is nothing until you continue.
    public func clear(_ signal: WrapUpSignal) {
        counts[signal] = logged[signal]
        if logged[signal, default: 0] == 0 { notes[signal] = nil }
    }

    /// A one-line note. A note means it happened, so an unset tile counts one.
    public func setNote(_ text: String, for signal: WrapUpSignal) {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        notes[signal] = line.isEmpty ? nil : line
        if !line.isEmpty, counts[signal, default: 0] == 0 { counts[signal] = 1 }
    }

    /// The count a tile shows: "-" while unset, never 0.
    public func countText(_ signal: WrapUpSignal) -> String {
        let count = counts[signal, default: 0]
        return count > 0 ? "\(count)" : "-"
    }

    /// Logs every count not written yet, one entry each, the note on the first, then goes on to Ready to close.
    @discardableResult
    public func continueFromSignals(writer: any WrapUpWriting) async -> Bool {
        guard step == .signals, !busy else { return false }
        busy = true
        defer { busy = false }
        for signal in WrapUpSignal.allCases {
            while logged[signal, default: 0] < counts[signal, default: 0] {
                let first = logged[signal, default: 0] == 0
                let request = LogRequest(text: signal.label, kind: signal.kind, date: day.date, note: first ? notes[signal] : nil)
                guard await writer.log(request) else { return false }
                logged[signal, default: 0] += 1
            }
        }
        step = .ready
        return true
    }

    // MARK: Ready to close

    public var done: Int {
        day.plan.filter { $0.status == .done }.count + answers.values.filter { $0 == .done }.count
    }

    public var items: Int { day.items + logged.values.reduce(0, +) }

    /// "4 of 5 done, and 9 items logged."
    public var closing: String { Self.closing(done: done, planned: day.plan.count, items: items) }

    public static func closing(done: Int, planned: Int, items: Int) -> String {
        let logged = items == 1 ? String(localized: "1 item logged") : items == 0 ? String(localized: "no items logged") : String(localized: "\(items) items logged")
        return planned == 0 ? String(localized: "Nothing was planned, and \(logged).") : String(localized: "\(done) of \(planned) done, and \(logged).")
    }

    /// Seals the day. With `copy`, the stand-up with its witness code goes to `pasteboard`; yesterday has no stand-up.
    @discardableResult
    public func seal(copy: Bool, writer: any WrapUpWriting, pasteboard: (String) -> Void) async -> SealResult? {
        guard step == .ready, sealed == nil, !busy else { return nil }
        busy = true
        defer { busy = false }
        let standup = copy && !day.isYesterday
        guard let result = await writer.seal(day: day.date, standup: standup) else { return nil }
        if standup, let text = result.standup { pasteboard(text) }
        sealed = result.sealed
        return result.sealed
    }

    /// Puts the flow at a step without writing. Specimens only.
    func show(_ step: WrapUpStep, preview: String? = nil, counts: [WrapUpSignal: Int] = [:], sealed: SealResult? = nil) {
        self.step = step
        self.preview = preview
        self.counts = counts
        self.sealed = sealed
    }
}

/// What the wrap-up sheet does outside itself.
public struct WrapUpActions {
    public var writer: (any WrapUpWriting)?
    public var sound: CadenceSoundPlayer?
    /// Puts the stand-up on the pasteboard.
    public var copy: @MainActor (String) -> Void
    /// The stand-up for a day as it reads now, without a witness code. Reads only.
    public var preview: @MainActor (LocalDate) async -> String?
    public var close: @MainActor () -> Void

    public init(
        writer: (any WrapUpWriting)?, sound: CadenceSoundPlayer?, copy: @escaping @MainActor (String) -> Void = WrapUpActions.pasteboard,
        preview: @escaping @MainActor (LocalDate) async -> String?, close: @escaping @MainActor () -> Void
    ) {
        self.writer = writer
        self.sound = sound
        self.copy = copy
        self.preview = preview
        self.close = close
    }

    @MainActor public static func pasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Does nothing. Specimens only.
    static var none: WrapUpActions {
        WrapUpActions(writer: nil, sound: nil, copy: { _ in }, preview: { _ in nil }, close: {})
    }
}

public struct WrapUpSheet: View {
    @Bindable var flow: WrapUpFlow
    let titles: SheetTitles
    let issue: StoreFailure?
    let showsTempo: Bool
    let tempo: SheetTempo?
    let actions: WrapUpActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var noteFor: WrapUpSignal?
    @State private var noteDraft = ""
    @FocusState private var noteFocused: Bool

    /// Press and hold this long on a tile to write its note.
    static let holdToNote: Double = 0.5

    public init(
        flow: WrapUpFlow, titles: SheetTitles, issue: StoreFailure? = nil, showsTempo: Bool, tempo: SheetTempo?,
        actions: WrapUpActions
    ) {
        self.flow = flow
        self.titles = titles
        self.issue = issue
        self.showsTempo = showsTempo
        self.tempo = tempo
        self.actions = actions
    }

    public var body: some View {
        SheetFrame(label: flow.day.isYesterday ? String(localized: "Wrap up \(SheetDate.weekday(flow.day.date))") : String(localized: "Wrap up")) {
            StepBar(current: flow.stepIndex, count: flow.stepCount)
            switch flow.step {
            case .task: taskStep
            case .reason: reasonStep
            case .signals: signalsStep
            case .ready: readyStep
            }
            SheetIssue(issue: issue)
        }
        .overlay {
            if flow.sealed != nil {
                SealingView(tempo: tempo, showsTempo: showsTempo)
                    .clipShape(RoundedRectangle(cornerRadius: SheetLayout.radius, style: .continuous))
                    .task {
                        try? await Task.sleep(for: .seconds(SealingView.duration(reduceMotion: reduceMotion)))
                        actions.close()
                    }
            }
        }
        .task(id: flow.step) {
            guard flow.step == .ready, !flow.day.isYesterday, flow.preview == nil else { return }
            flow.preview = await actions.preview(flow.day.date)
        }
    }

    private var notYet: some View {
        Button("Not yet", action: actions.close)
            .buttonStyle(SheetButtonStyle(kind: .link))
            .keyboardShortcut(.cancelAction)
    }

    private func run(_ work: @escaping @MainActor (any WrapUpWriting) async -> Void) {
        guard let writer = actions.writer else { return }
        Task { await work(writer) }
    }

    // MARK: Each open task

    @ViewBuilder private var taskStep: some View {
        let index = flow.stepIndex
        SheetKicker(flow.taskKicker)
        SheetTitle(titles(flow.current?.title ?? "", index: index))
        SheetLead(String(localized: "How did this one go?"))
        if let note = flow.mergedNote {
            SheetLead(note, color: CadenceColor.ink2)
                .padding(.top, CadenceSpace.s4)
        }
        HStack(spacing: CadenceSpace.s8) {
            Button {
                run { await flow.answer(.done, writer: $0) }
            } label: {
                HStack(spacing: CadenceSpace.s4) {
                    Text("Done")
                    KeyCap(keys: "D", inverted: true)
                }
            }
            .buttonStyle(SheetButtonStyle(kind: .primaryChoice))
            .keyboardShortcut("d", modifiers: [])
            .accessibilityHint("D")
            Button {
                flow.move()
            } label: {
                HStack(spacing: CadenceSpace.s4) {
                    Text(flow.moveLabel)
                    KeyCap(keys: "M")
                }
            }
            .buttonStyle(SheetButtonStyle(kind: .choice))
            .keyboardShortcut("m", modifiers: [])
            .accessibilityHint("M")
            Button {
                run { await flow.answer(.dropped, writer: $0) }
            } label: {
                HStack(spacing: CadenceSpace.s4) {
                    Text("Drop it")
                    KeyCap(keys: "X")
                }
            }
            .buttonStyle(SheetButtonStyle(kind: .choice))
            .keyboardShortcut("x", modifiers: [])
            .accessibilityHint("X")
            // Done is the primary action, so it answers to Command Return too.
            Button("Done") { run { await flow.answer(.done, writer: $0) } }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .disabled(flow.busy)
        .padding(.top, CadenceSpace.s12)
        SheetFooter { notYet } trailing: { EmptyView() }
    }

    @ViewBuilder private var reasonStep: some View {
        SheetKicker(flow.moveLabel)
        SheetTitle(titles(flow.current?.title ?? "", index: flow.stepIndex))
        SheetLead(WrapUpFlow.reasonPrompt)
        HStack(spacing: CadenceSpace.s8) {
            ForEach(SlipReason.allCases, id: \.self) { reason in
                Button(reason.label) { run { await flow.answer(.moved(reason), writer: $0) } }
                    .buttonStyle(SheetButtonStyle(kind: .choice))
            }
        }
        .disabled(flow.busy)
        .padding(.top, CadenceSpace.s12)
        SheetFooter { notYet } trailing: { EmptyView() }
    }

    // MARK: Anything else today?

    @ViewBuilder private var signalsStep: some View {
        SheetKicker(String(localized: "Anything else today?"))
        SheetTitle(String(localized: "Tap what happened."))
        SheetLead(String(localized: "Tap to count, and press and hold to add a note."))
        let columns = Array(repeating: GridItem(.flexible(), spacing: CadenceSpace.s8), count: 2)
        LazyVGrid(columns: columns, spacing: CadenceSpace.s8) {
            ForEach(WrapUpSignal.allCases) { signal in
                SignalTile(
                    signal: signal, count: flow.countText(signal), note: flow.notes[signal],
                    onTap: { flow.tap(signal) }, onHold: { openNote(signal) }, onClear: { flow.clear(signal) })
            }
        }
        .padding(.top, CadenceSpace.s12)
        if let signal = noteFor {
            noteField(signal)
        }
        SheetFooter {
            notYet
        } trailing: {
            Button {
                saveNote()
                run { await flow.continueFromSignals(writer: $0) }
            } label: {
                HStack(spacing: CadenceSpace.s4) {
                    Text("Continue")
                    KeyCap(keys: "⌘↩", inverted: true)
                }
            }
            .buttonStyle(SheetButtonStyle(kind: .primary))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(flow.busy)
        }
    }

    private func openNote(_ signal: WrapUpSignal) {
        saveNote()
        noteFor = signal
        noteDraft = flow.notes[signal] ?? ""
        noteFocused = true
    }

    private func saveNote() {
        guard let signal = noteFor else { return }
        flow.setNote(noteDraft, for: signal)
        noteFor = nil
        noteDraft = ""
    }

    private func noteField(_ signal: WrapUpSignal) -> some View {
        HStack(spacing: CadenceSpace.s8) {
            Text(signal.label)
                .cadenceType(CadenceType.comparison)
                .foregroundStyle(CadenceColor.ink3.color)
                .lineLimit(1)
                .fixedSize()
            TextField("Add a one-line note", text: $noteDraft)
                .textFieldStyle(.plain)
                .cadenceType(CadenceType.body)
                .foregroundStyle(CadenceColor.ink.color)
                .focused($noteFocused)
                .onSubmit(saveNote)
                .accessibilityLabel("Note for \(signal.label)")
        }
        .padding(.horizontal, CadenceSpace.s12)
        .frame(height: CadenceSize.controlPrimary)
        .background(RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous).fill(CadenceColor.track.color))
        .padding(.top, CadenceSpace.s8)
    }

    // MARK: Ready to close

    @ViewBuilder private var readyStep: some View {
        SheetKicker(flow.readyKicker)
        SheetTitle(flow.closing)
        if flow.day.isYesterday {
            SheetLead(WrapUpFlow.lateSeal, color: CadenceColor.ink2)
            SheetFooter {
                notYet
            } trailing: {
                Button {
                    seal(copy: false)
                } label: {
                    HStack(spacing: CadenceSpace.s4) {
                        Text(flow.sealLabel)
                        KeyCap(keys: "⌘↩", inverted: true)
                    }
                }
                .buttonStyle(SheetButtonStyle(kind: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(flow.busy || flow.sealed != nil)
            }
        } else {
            SheetLead(WrapUpFlow.standupLead, color: CadenceColor.ink2)
            StandupPreview(text: titles.discreet ? nil : flow.preview, discreet: titles.discreet)
                .padding(.top, CadenceSpace.s8)
            SheetFooter {
                notYet
            } trailing: {
                Button("Seal only") { seal(copy: false) }
                    .buttonStyle(SheetButtonStyle(kind: .quiet))
                    .disabled(flow.busy || flow.sealed != nil)
                Button {
                    seal(copy: true)
                } label: {
                    HStack(spacing: CadenceSpace.s4) {
                        Text("Copy stand-up and seal")
                        KeyCap(keys: "⌘↩", inverted: true)
                    }
                }
                .buttonStyle(SheetButtonStyle(kind: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(flow.busy || flow.sealed != nil)
            }
            Text(WrapUpFlow.copyHint)
                .cadenceType(CadenceType.comparison)
                .foregroundStyle(CadenceColor.ink3.color)
                .padding(.top, CadenceSpace.s8)
        }
    }

    private func seal(copy: Bool) {
        run { writer in
            guard await flow.seal(copy: copy, writer: writer, pasteboard: actions.copy) != nil else { return }
            // The trackpad tap comes from the menu-bar mark as the day becomes sealed, so it plays once.
            actions.sound?.play(.ringClosed)
        }
    }
}

/// The stand-up as it will read. Skeleton lines while it is read; hidden in discreet mode, since it has titles.
struct StandupPreview: View {
    let text: String?
    let discreet: Bool

    /// Skeleton lines stand in for the text while it is read.
    private static let skeleton: [CGFloat] = [0.4, 0.9, 0.75, 0.6]

    var body: some View {
        Group {
            if discreet {
                Text("The stand-up is hidden while discreet mode is on.")
                    .cadenceType(CadenceType.comparison)
                    .foregroundStyle(CadenceColor.ink3.color)
            } else if let text {
                Text(text)
                    .cadenceType(CadenceType.figure)
                    .foregroundStyle(CadenceColor.ink.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: CadenceSpace.s8) {
                        ForEach(Self.skeleton, id: \.self) { share in
                            Capsule()
                                .fill(CadenceColor.ink.color.opacity(SheetLayout.addFill))
                                .frame(width: geometry.size.width * share, height: CadenceSpace.s8)
                        }
                    }
                }
                .frame(height: CadenceSpace.s8 * 7)
                .accessibilityLabel("Reading your stand-up")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CadenceSpace.s12)
        .padding(.vertical, CadenceSpace.s8)
        .background(RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous).fill(CadenceColor.track.color))
    }
}

/// A tile: tap to count, press and hold for a note (section 6.5, SignalTile). Unset reads "-".
struct SignalTile: View {
    let signal: WrapUpSignal
    let count: String
    let note: String?
    let onTap: () -> Void
    let onHold: () -> Void
    let onClear: () -> Void

    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: CadenceSpace.s8) {
            Circle()
                .fill(CadenceColor.family(signal.family).color)
                .frame(width: SheetLayout.familyDot, height: SheetLayout.familyDot)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(signal.label)
                    .cadenceType(SheetType.choice)
                    .foregroundStyle(CadenceColor.ink.color)
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .cadenceType(CadenceType.comparison)
                        .foregroundStyle(CadenceColor.ink3.color)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(count)
                .cadenceType(SheetType.tileCount)
                .foregroundStyle(CadenceColor.ink.color)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, CadenceSpace.s12)
        .frame(height: SheetLayout.tileHeight)
        .background(
            RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous)
                .fill(hover ? CadenceColor.ink.color.opacity(SheetLayout.addFill) : CadenceColor.track.color)
        )
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous)
                    .stroke(CadenceColor.focus.color, lineWidth: SheetLayout.tickStroke)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous))
        .gesture(
            LongPressGesture(minimumDuration: WrapUpSheet.holdToNote)
                .exclusively(before: TapGesture())
                .onEnded { value in
                    switch value {
                    case .first: onHold()
                    case .second: onTap()
                    }
                }
        )
        .onHover { hover = $0 }
        .focusable()
        .focused($focused)
        .onKeyPress(.space) {
            onTap()
            return .handled
        }
        .onKeyPress(.return) {
            onHold()
            return .handled
        }
        // Clear is on the context menu and the VoiceOver actions; ⌫ reaches it from the keyboard.
        .onKeyPress(.delete) {
            onClear()
            return .handled
        }
        .contextMenu {
            Button("Add a note", action: onHold)
            Button("Clear", action: onClear)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(signal.label)
        .accessibilityValue(count == "-" ? String(localized: "Not set") : count + (note.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Space counts one. Return adds a note. Delete clears.")
        .accessibilityAction(.default, onTap)
        .accessibilityAction(named: "Add a note", onHold)
        .accessibilityAction(named: "Clear", onClear)
    }
}
