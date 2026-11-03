import CadenceCore
import Foundation
import Observation
import SwiftUI

/// The one model every surface reads and acts through (docs/SPEC.md sections 4 and 8.2): the day as read, the
/// story told from it, what only the app knows, and every action a surface can take. Actions go through the
/// writer and reload at once, so no surface shows what the ledger refused. The one exception is the panel's
/// tick, held for its Undo (docs/decisions/README.md, T3.29 and T3.30).
@MainActor @Observable
public final class AppState {
    /// A tick waiting out its Undo.
    public struct PendingTick: Sendable, Equatable {
        public var task: String
        public var since: Date
    }

    /// How long a tick waits for Undo before it is written (section 4.2).
    public static let undoWindow: TimeInterval = 4

    public let model: DayModel
    @ObservationIgnored public let writer: AppWriter
    public var signals = AppSignals()
    /// Titles become "Task 1" and "Item 1", ticket keys and Tempo are hidden (section 6.7).
    public var discreet = false
    /// Tempo can be turned off in Settings; discreet mode also hides it.
    public var tempoEnabled = true
    /// The system will not show Cadence's notifications. The window says so until "Not now" (section 4.6).
    public var notificationsOff = false
    public var notificationsNoticeDismissed = false
    /// The last write that failed, for a banner. Cleared by the next write that succeeds.
    public private(set) var issue: StoreFailure?
    public private(set) var pendingTick: PendingTick?
    /// The words of the last line that could not be saved, kept for "Copy my text" (section 4.6).
    public private(set) var unsavedText: String?
    /// Told after every line the person logs, for the `capture.saved` sound.
    @ObservationIgnored public var onLogged: (@MainActor () -> Void)?
    /// Says a line to VoiceOver, politely. A tick says "Done, 3 of 5" here, whichever surface it came from (section 6.7).
    @ObservationIgnored public var announce: @MainActor (String) -> Void = { AppState.speak($0) }

    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private var pendingTask: Task<Void, Never>?

    public init(model: DayModel, writer: AppWriter, clock: any Clock) {
        self.model = model
        self.writer = writer
        self.clock = clock
    }

    // MARK: reading

    public var now: Date { clock.now() }

    public var state: DayState? { model.state }

    public var context: DayContext? { model.state?.context }

    /// The day the store is read for, or the calendar day while nothing has been read.
    public var today: LocalDate {
        model.state?.day ?? DayBoundary.standard.day(of: clock.now(), in: .current)
    }

    public var story: DayStory? { model.load.story(signals: signals, at: clock.now(), today: today) }

    /// Tempo shows only when it is on and discreet mode is off.
    public var showsTempo: Bool { tempoEnabled && !discreet }

    /// A task's status as the surfaces show it: a tick waiting for Undo already reads as done.
    public func status(of task: PlanTask) -> TaskStatus {
        pendingTick?.task == task.id ? .done : task.status
    }

    /// Done over planned as the surfaces show it.
    public var shownDone: Int {
        guard let plan = context?.plan else { return 0 }
        return plan.filter { status(of: $0) == .done }.count
    }

    /// A title as a surface may show it.
    public func title(_ text: String, index: Int, word: String = String(localized: "Item")) -> String {
        discreet ? "\(word) \(index + 1)" : text
    }

    // MARK: acting

    /// Ticks an open task. It reads as done at once and is written when the Undo window passes, when the
    /// panel closes, or when the app quits. Ticking another task first writes the one waiting.
    ///
    /// `plan` is the plan the task belongs to, for what VoiceOver says ("Done, 2 of 3"): today's unless the task is on a
    /// reopened earlier day.
    public func tick(_ task: PlanTask, among plan: [PlanTask]? = nil) {
        guard task.status == .open, pendingTick?.task != task.id else { return }
        // The waiting tick is written under its own id before the new one takes its place, so neither is lost.
        let waiting = pendingTick
        if let waiting {
            Task { _ = await perform(.resolve(task: waiting.task, status: .done, reason: nil)) }
        }
        pendingTick = PendingTick(task: task.id, since: clock.now())
        // Said once per tick, here, so Today and the panel never say it twice. The tick that was waiting is done too,
        // though the read that shows it has not come back yet.
        let plan = plan ?? context?.plan ?? []
        let done = plan.filter { $0.status == .done || $0.id == task.id || $0.id == waiting?.task }.count
        announce(Self.tickAnnouncement(done: done, planned: plan.count))
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoWindow))
            guard !Task.isCancelled else { return }
            await self?.flushPendingTick()
        }
    }

    /// What VoiceOver says when a task is ticked.
    public nonisolated static func tickAnnouncement(done: Int, planned: Int) -> String {
        String(localized: "Done, \(done) of \(planned)")
    }

    private static func speak(_ words: String) {
        var announcement = AttributedString(words)
        announcement.accessibilitySpeechAnnouncementPriority = .default
        AccessibilityNotification.Announcement(announcement).post()
    }

    /// Takes back the waiting tick. Nothing was written.
    public func undoTick() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingTick = nil
    }

    /// Writes the waiting tick now, if there is one.
    public func flushPendingTick() async {
        guard let task = takePendingTick() else { return }
        _ = await perform(.resolve(task: task, status: .done, reason: nil))
    }

    /// Hands over the waiting tick's task id and forgets it, for a caller that writes it itself: quitting cannot wait
    /// for the main actor, so it writes through the writer directly.
    public func takePendingTick() -> String? {
        guard let pending = pendingTick else { return nil }
        pendingTask?.cancel()
        pendingTask = nil
        pendingTick = nil
        return pending.task
    }

    /// Logs a line. `kind` is the one the person picked on the field's chip; without it Core reads the kind from the
    /// words. `links` are added to any the line carries. `day` is the day the line is for, when it is not today: a
    /// reopened day logs onto itself.
    @discardableResult
    public func log(_ text: String, kind: EntryKind? = nil, links: [CadenceCore.Link] = [], day: LocalDate? = nil) async -> Entry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let request = LogRequest(text: trimmed, kind: kind, date: day, links: links)
        if case .entry(let entry)? = await perform(.log(request)) { return entry }
        return nil
    }

    @discardableResult
    public func resolve(_ task: String, as status: TaskStatus, reason: String? = nil) async -> Bool {
        await perform(.resolve(task: task, status: status, reason: reason)) != nil
    }

    /// Move to tomorrow (section 4.5): slipped here with a reason chip, carried to the next workday.
    @discardableResult
    public func move(_ task: String, reason: SlipReason) async -> Bool {
        await perform(.move(task: task, reason: reason.rawValue)) != nil
    }

    /// The morning plan (section 4.4): adds the typed tasks, drops the carried tasks not picked, then commits the
    /// picked and added tasks in that order.
    @discardableResult
    public func commitPlan(picked: [String], added: [String], focus: String? = nil) async -> Bool {
        let carried = context?.carried ?? []
        var order = picked
        for title in added {
            guard case .task(let task)? = await perform(.planAdd(title: title, day: nil)) else { return false }
            order.append(task.id)
        }
        for task in carried where !picked.contains(task.id) {
            guard await perform(.resolve(task: task.id, status: .dropped, reason: nil)) != nil else { return false }
        }
        return await perform(.planCommit(day: nil, tasks: order, focus: focus)) != nil
    }

    /// Seals a day, after writing any waiting tick. Returns the stand-up when asked for it.
    public func seal(day: LocalDate? = nil, standup: Bool) async -> (sealed: SealResult, standup: String?)? {
        await flushPendingTick()
        var text: String?
        if standup, case .standup(let body, _)? = await perform(.standup(day: day)) { text = body }
        guard case .sealed(let result)? = await perform(.seal(day: day)) else { return nil }
        return (result, text)
    }

    /// Opens a sealed day again, whichever day it is, so it can be changed and sealed again (section 3). The ledger keeps
    /// every earlier seal. A refusal (the day is not sealed) goes to the banner like any other.
    @discardableResult
    public func reopen(day: LocalDate? = nil) async -> Bool {
        await flushPendingTick()
        return await perform(.reopen(day: day)) != nil
    }

    /// Not working today (section 4.2): leave, sick (leave labelled "sick") or holiday.
    @discardableResult
    public func declare(_ off: DayStory.DayOff, day: LocalDate? = nil) async -> Bool {
        let kind: DayKind
        var label: String?
        switch off {
        case .leave: kind = .leaveUnplanned
        case .sick:
            kind = .leaveUnplanned
            label = "sick"
        case .holiday: kind = .holiday
        case .weekend: return false
        }
        return await perform(.declare(day: day ?? today, kind: kind, label: label)) != nil
    }

    /// Working after all: the day is a workday again.
    @discardableResult
    public func workingAfterAll(day: LocalDate? = nil) async -> Bool {
        await perform(.declare(day: day ?? today, kind: .workday, label: nil)) != nil
    }

    /// Edits an entry's title, kind or links (section 4.6). `links` is the whole list after the edit. The history keeps
    /// every version; the origin never changes.
    @discardableResult
    public func editEntry(
        _ entry: String, title: String? = nil, kind: EntryKind? = nil, links: [CadenceCore.Link]? = nil
    ) async -> Bool {
        await perform(.editEntry(entry: entry, title: title, kind: kind, links: links)) != nil
    }

    @discardableResult
    public func setStatus(_ entry: String, to status: EntryStatus) async -> Bool {
        await perform(.setStatus(entry: entry, status: status)) != nil
    }

    /// Every write: through the writer, then a reload at once. A failure is kept for the banner.
    @discardableResult
    public func perform(_ action: WriteAction) async -> WriteResult? {
        let result = await writer.perform(action)
        model.reload()
        switch result {
        case .success(let value):
            issue = nil
            if case .log = action {
                unsavedText = nil
                onLogged?()
            }
            return value
        case .failure(let failure):
            issue = failure
            if case .log(let request) = action { unsavedText = request.text }
            return nil
        }
    }

    public func dismissIssue() { issue = nil }
}
