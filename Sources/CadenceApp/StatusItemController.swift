// The status item and its mark: an AppKit item of fixed length, not MenuBarExtra, which cannot do right-click menus
// or custom animation (docs/SPEC.md section 4.1). The mark is drawn from the day's story; a display link runs only
// while a motion plays, so an idle mark costs nothing. A click toggles the panel; a right-click or Control-click
// opens the native menu, built from the same state the panel shows.
import AppKit
import CadenceCore
import CadenceUI
import Observation

@MainActor
final class StatusItemController: NSObject {
    /// What only the app knows about the day: paused, a source behind, an import, setup. Fed from AppState.
    var signals = AppSignals() {
        didSet { if signals != oldValue { refresh() } }
    }
    /// Discreet mode: the ring alone, for screen sharing.
    var discreet = false {
        didSet { if discreet != oldValue { refresh() } }
    }

    /// What the mark shows now. A nil state is the moment before the first read.
    private struct Shown: Equatable {
        var state: DayStory.State?
        var voice: String
        var form: MarkForm
        var discreet: Bool
    }

    private let item = NSStatusBar.system.statusItem(withLength: CadenceMarkTokens.side)
    private let app: AppState
    private let pause: CapturePause
    private let panel: PanelController
    private let actions: PanelActions
    private var model: DayModel { app.model }
    private var shown: Shown?
    private var hover = false
    private var appearanceObservation: NSKeyValueObservation?

    // Motion in flight, each from the time it started.
    private var fadeFrom: NSImage?
    private var fadeStart: CFTimeInterval = 0
    private var riseFrom: Double?
    private var riseStart: CFTimeInterval = 0
    private var sealStart: CFTimeInterval?
    private var breathStart: CFTimeInterval?
    private var link: CADisplayLink?

    init(app: AppState, pause: CapturePause, panel: PanelController, actions: PanelActions) {
        self.app = app
        self.pause = pause
        self.panel = panel
        self.actions = actions
        super.init()
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.addTrackingArea(
                NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.drawFrame() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        observe()
    }

    /// Re-arms itself: Observation fires once per change.
    private func observe() {
        let (signals, discreet) = withObservationTracking {
            _ = model.load
            _ = app.pendingTick
            return (app.signals, app.discreet)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        self.signals = signals
        self.discreet = discreet
        refresh()
    }

    // MARK: Click and menu

    @objc private func clicked() {
        guard let button = item.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            panel.close()
            showMenu(from: button)
        } else {
            panel.toggle(below: button)
        }
    }

    /// The panel's highlight: the native rounded highlight sits behind the mark while it is open.
    func panelVisibilityChanged(_ open: Bool) {
        item.button?.highlight(open)
    }

    private func showMenu(from button: NSStatusBarButton) {
        let input = PanelInput.from(app, pausedUntil: pause.until)
        let end = CapturePause.suggestedEnd(after: app.now)
        let items = StatusMenuItem.items(
            PanelContent(input), paused: app.signals.paused, pauseUntil: Timestamp.clockTime(end, in: .current))
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in items { menu.addItem(menuItem(entry, pauseEnd: end)) }
        // Assigned only for this click, so a left click keeps toggling the panel.
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    private func menuItem(_ entry: StatusMenuItem, pauseEnd: Date) -> NSMenuItem {
        if entry == .separator { return .separator() }
        let menuItem = ClosureMenuItem(title: entry.title)
        switch entry {
        case .logSomething:
            menuItem.keyEquivalent = "l"
            menuItem.keyEquivalentModifierMask = [.control, .option]
            menuItem.run = { [actions] in actions.openCapture() }
        case .nextStep(let action):
            menuItem.run = { [actions] in actions.run(action) }
        case .openCadence:
            menuItem.keyEquivalent = "o"
            menuItem.run = { [actions] in actions.openWindow(.today) }
        case .pause:
            menuItem.run = { [pause] in pause.pause(until: pauseEnd) }
        case .resume:
            menuItem.run = { [pause] in pause.resume() }
        case .notWorkingToday:
            let submenu = NSMenu()
            for (off, title) in StatusMenuItem.daysOff {
                let day = ClosureMenuItem(title: title)
                day.run = { [app] in Task { await app.declare(off) } }
                submenu.addItem(day)
            }
            menuItem.submenu = submenu
        case .settings:
            menuItem.keyEquivalent = ","
            menuItem.run = { [actions] in actions.openSettings(.general) }
        case .quit:
            menuItem.keyEquivalent = "q"
            // A tick waiting for Undo is written before the app goes.
            menuItem.run = { [app] in
                Task {
                    await app.flushPendingTick()
                    NSApp.terminate(nil)
                }
            }
        case .separator:
            break
        }
        return menuItem
    }

    // MARK: State

    private func refresh() {
        apply(current())
    }

    private func current() -> Shown {
        let now = Date()
        let today = LocalDate(String(Timestamp.local(now, in: .current).prefix(10))) ?? LocalDate(year: 1970, month: 1, day: 1)!
        guard let story = model.load.story(signals: signals, at: now, today: today) else {
            return Shown(state: nil, voice: String(localized: "Cadence"), form: .discreet, discreet: discreet)
        }
        var planned = 0
        var resolved = 0
        if case .loaded(let state) = model.load {
            if let context = state.context {
                planned = context.plan.count
                // A tick held for Undo already reads as done in the panel, so the water rises with it.
                let held = context.plan.contains { $0.id == app.pendingTick?.task && $0.status == .open }
                resolved = context.resolved + (held ? 1 : 0)
            } else {
                planned = state.planned
                resolved = state.resolved
            }
        }
        let level = MarkForm.level(story.state, planned: planned, resolved: resolved, importing: signals.importing)
        let form = MarkForm(
            state: story.state, level: level, allResolved: planned > 0 && resolved >= planned, discreet: discreet)
        return Shown(state: story.state, voice: story.voice, form: form, discreet: discreet)
    }

    private func apply(_ next: Shown) {
        guard next != shown else { return }
        let previous = shown
        shown = next
        item.button?.setAccessibilityLabel(next.voice)
        item.button?.toolTip = next.voice

        guard let previous else {
            // The first state at launch appears; there is nothing to move from.
            drawFrame()
            return
        }
        if previous.voice != next.voice { announce(next.voice) }
        if let state = next.state, MarkForm.isSealed(state), !(previous.state.map(MarkForm.isSealed) ?? false) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        // A problem stays calm, and Reduce Motion drops every change to its end state.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || next.state == .storeProblem {
            stopMotion()
            drawFrame()
            return
        }

        let now = CACurrentMediaTime()
        let stateChanged = previous.state != next.state || previous.discreet != next.discreet
        var oldShape = previous.form
        var newShape = next.form
        oldShape.water = nil
        newShape.water = nil
        if !stateChanged, oldShape == newShape, let water = next.form.water, water.level != previous.form.water?.level {
            // A tick: the water rises from where it is now, mid-rise included.
            riseFrom = displayedLevel(at: now, target: previous.form.water?.level) ?? previous.form.water?.level ?? 0
            riseStart = now
        } else if previous.form != next.form || stateChanged {
            fadeFrom = item.button?.image.flatMap(rasterized)
            fadeStart = now
            riseFrom = nil
            sealStart = next.form.solid != nil && previous.form.solid == nil ? now : nil
            breathStart = next.form.attention && stateChanged ? now : nil
        }
        drawFrame()
        startLinkIfNeeded()
    }

    /// The water level on screen while a rise toward `target` plays.
    private func displayedLevel(at now: CFTimeInterval, target: Double?) -> Double? {
        guard let riseFrom, let target else { return nil }
        let p = (now - riseStart) / CadenceMotion.markRise.duration
        guard p < 1 else { return nil }
        return riseFrom + (target - riseFrom) * CadenceMotion.easeProgress(p)
    }

    // MARK: Drawing

    private var bar: MarkBar {
        MarkBar(
            appearance: item.button?.effectiveAppearance ?? NSApp.effectiveAppearance,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }

    /// What the last still frame was drawn from. Setting the button's image makes AppKit redraw every replicant of the
    /// item (and can report an appearance change), so an unchanged still frame is never set again: an idle mark costs
    /// nothing.
    private var lastStill: (form: MarkForm, bar: MarkBar, hover: Bool)?

    /// Draws the mark as it is at this instant, and reports whether any motion is still playing.
    @discardableResult
    private func drawFrame() -> Bool {
        guard let shown, let button = item.button else { return false }
        let now = CACurrentMediaTime()
        let bar = self.bar
        var motion = MarkMotion(hover: hover)
        var playing = false

        if riseFrom != nil {
            let p = (now - riseStart) / CadenceMotion.markRise.duration
            if p < 1 {
                motion.riseFrom = riseFrom
                motion.rise = p
                playing = true
            } else {
                riseFrom = nil
            }
        }
        if let sealStart {
            let p = (now - sealStart) / CadenceMotion.markSeal.duration
            if p < 1 {
                motion.seal = p
                playing = true
            } else {
                self.sealStart = nil
            }
        }
        if let breathStart {
            let elapsed = now - breathStart
            let one = CadenceMotion.breath.duration
            if elapsed < one * Double(CadenceMotion.breaths) {
                motion.breath = (elapsed / one).truncatingRemainder(dividingBy: 1)
                playing = true
            } else {
                self.breathStart = nil
            }
        }
        var image = MarkRenderer.image(shown.form, bar: bar, motion: motion)
        if let fadeFrom {
            let p = (now - fadeStart) / CadenceMotion.world.duration
            if p < 1 {
                image = MarkRenderer.crossfade(from: fadeFrom, to: image, fraction: p)
                playing = true
            } else {
                self.fadeFrom = nil
            }
        }
        if playing {
            lastStill = nil
        } else {
            if let last = lastStill, last.form == shown.form, last.bar == bar, last.hover == hover { return false }
            lastStill = (shown.form, bar, hover)
        }
        button.image = image
        return playing
    }

    /// A crossfade starts from a flat copy of what is on screen, so fades never nest.
    private func rasterized(_ image: NSImage) -> NSImage? {
        let scale = item.button?.window?.backingScaleFactor ?? 2
        let size = MarkRenderer.size
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let flat = NSImage(size: size)
        flat.addRepresentation(rep)
        return flat
    }

    // MARK: Motion

    private func startLinkIfNeeded() {
        let playing = fadeFrom != nil || riseFrom != nil || sealStart != nil || breathStart != nil
        guard playing, link == nil, let button = item.button else { return }
        let link = button.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        if !drawFrame() { stopLink() }
    }

    private func stopMotion() {
        fadeFrom = nil
        riseFrom = nil
        sealStart = nil
        breathStart = nil
        stopLink()
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    // MARK: Hover, VoiceOver, display options

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        hover = true
        if link == nil { drawFrame() }
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        hover = false
        if link == nil { drawFrame() }
    }

    /// Changes are announced politely, and only when the words changed.
    private func announce(_ voice: String) {
        guard let button = item.button else { return }
        NSAccessibility.post(
            element: button, notification: .announcementRequested,
            userInfo: [.announcement: voice, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    @objc private func displayOptionsChanged() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { stopMotion() }
        drawFrame()
    }
}

/// A menu item that runs a closure.
@MainActor
private final class ClosureMenuItem: NSMenuItem {
    var run: (() -> Void)?

    init(title: String) {
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run?() }
}
