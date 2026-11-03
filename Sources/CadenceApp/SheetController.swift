// The window every sheet lives in (docs/SPEC.md sections 4.4, 4.5, 4.8 and 6.4): a floating panel 540 points wide
// whose top edge never moves, so stepping through a flow only grows or shrinks it downward. The panel, notifications
// and the window all open sheets through this one controller. Glass comes from the sheet itself, with its solid
// fallback under Reduce Transparency. `⌘↩` runs the primary action and `esc` closes.
import AppKit
import CadenceCore
import CadenceUI
import SwiftUI

@MainActor
final class SheetWindowController: NSObject, NSWindowDelegate {
    private let app: AppState
    private let sound: CadenceSoundPlayer?
    private let reader: StoreReader
    /// Draws Tempo; the sealing moment shows its blanket pose. Nil leaves the slot empty.
    var tempo: SheetTempo?
    private var panel: SheetPanel?
    private var hosting: TopPinnedHostingView?
    /// Kept while the sheet is closed with "Later", so reopening it the same day shows the picks as they were.
    private var plan: PlanSheetModel?
    /// Kept while the wrap-up is closed with "Not yet", one per day, so the answers are there when it reopens.
    private var wraps: [LocalDate: WrapUpFlow] = [:]

    init(app: AppState, location: StoreLocation, sound: CadenceSoundPlayer?, tempo: SheetTempo? = nil) {
        self.app = app
        self.sound = sound
        self.reader = StoreReader(location: location, clock: SystemClock())
        self.tempo = tempo
        super.init()
    }

    var isShown: Bool { panel?.isVisible ?? false }

    // MARK: Morning plan

    /// Opens the morning plan for the day the app has read. Suggestions from collectors join only when picked.
    func showPlan(suggestions: [PlanSuggestion] = []) {
        if plan?.day != app.today { plan = nil }
        // Suggestions come from the day as read: open pull requests and tickets touched on the last workday.
        let suggested = suggestions.isEmpty
            ? (app.context?.suggestions ?? []).map { PlanSuggestion(title: $0.title, family: $0.family, reason: $0.reason) }
            : suggestions
        guard let model = plan ?? PlanSheetModel(app: app, suggestions: suggested) else { return }
        plan = model
        present(PlanSheetHost(app: app, model: model, controller: self))
    }

    fileprivate func startDay(_ model: PlanSheetModel) {
        Task {
            guard await model.commit(app: app, sound: sound) else { return }
            plan = nil
            close()
        }
    }

    fileprivate func declare(_ off: DayStory.DayOff) {
        Task {
            guard await app.declare(off) else { return }
            plan = nil
            close()
        }
    }

    // MARK: Wrap-up

    /// Opens today's wrap-up from the day the app has read.
    func showWrapUp() {
        guard let context = app.context, let day = WrapUpDay(context: context, today: app.today) else { return }
        showWrapUp(day)
    }

    /// Opens the wrap-up for an earlier day still inside its grace window ("Seal Wednesday"). That day is read
    /// afresh, since the app's model holds only today.
    func showWrapUp(previous date: LocalDate) {
        let today = app.today
        if let flow = wraps[date] {
            present(WrapUpSheetHost(app: app, flow: flow, controller: self))
            return
        }
        Task {
            guard let context = await reader.context(on: date), let day = WrapUpDay(context: context, today: today) else { return }
            showWrapUp(day)
        }
    }

    private func showWrapUp(_ day: WrapUpDay) {
        wraps = wraps.filter { $0.key >= day.date.adding(days: -1) }
        let flow = wraps[day.date] ?? WrapUpFlow(day: day)
        wraps[day.date] = flow
        present(WrapUpSheetHost(app: app, flow: flow, controller: self))
    }

    fileprivate func wrapActions(for flow: WrapUpFlow) -> WrapUpActions {
        WrapUpActions(
            writer: app, sound: sound,
            preview: { [reader] date in await reader.standup(on: date) },
            close: { [weak self, weak flow] in
                guard let self else { return }
                // A sealed day starts afresh if it is ever wrapped up again; an open one keeps its answers.
                if let flow, flow.sealed != nil { self.wraps[flow.day.date] = nil }
                self.close()
            })
    }

    // MARK: The panel

    private func present(_ root: some View) {
        let view = AnyView(root)
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = TopPinnedHostingView(rootView: view)
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.safeAreaRegions = []
            self.hosting = hosting
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let hosting else { return }
        if panel.contentView !== hosting { panel.contentView = hosting }

        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let top = visible.maxY - SheetLayout.topInset
        hosting.top = top
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)

        let wasVisible = panel.isVisible
        panel.makeKeyAndOrderFront(nil)
        guard !wasVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            return
        }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CadenceMotion.open.duration
            let c = CadenceMotion.ease
            context.timingFunction = CAMediaTimingFunction(controlPoints: Float(c.x1), Float(c.y1), Float(c.x2), Float(c.y2))
            panel.animator().alphaValue = 1
        }
    }

    private func makePanel() -> SheetPanel {
        let panel = SheetPanel(
            contentRect: NSRect(x: 0, y: 0, width: SheetLayout.width, height: SheetLayout.width),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    /// Closes the sheet. Answers stay with their model, so the next open picks up where this one stopped.
    func close() {
        panel?.orderOut(nil)
    }
}

/// A borderless panel that takes keys without activating the app, and closes on `esc`.
final class SheetPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Grows and shrinks downward from a fixed top edge when the sheet's content changes size.
final class TopPinnedHostingView: NSHostingView<AnyView> {
    var top: CGFloat?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.pinTop() }
    }

    private func pinTop() {
        guard let window, let top else { return }
        let size = fittingSize
        guard size != window.frame.size else { return }
        window.setFrame(NSRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }
}

/// Reads the app state so the sheet follows discreet mode, Tempo's setting and a failed write.
private struct WrapUpSheetHost: View {
    let app: AppState
    let flow: WrapUpFlow
    let controller: SheetWindowController

    var body: some View {
        WrapUpSheet(
            flow: flow, titles: SheetTitles(app: app), issue: app.issue, showsTempo: app.showsTempo,
            tempo: controller.tempo, actions: controller.wrapActions(for: flow))
    }
}

/// Reads the app state so the sheet follows discreet mode and shows a failed write.
private struct PlanSheetHost: View {
    let app: AppState
    let model: PlanSheetModel
    let controller: SheetWindowController

    var body: some View {
        PlanSheet(
            model: model, titles: SheetTitles(app: app), issue: app.issue,
            onStart: { controller.startDay(model) }, onLater: { controller.close() },
            onDayOff: { controller.declare($0) })
    }
}
