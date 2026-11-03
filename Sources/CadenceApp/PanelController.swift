// The menu-bar panel's window (docs/SPEC.md section 4.2): a non-activating NSPanel made at launch and kept warm,
// so it opens in under 100 ms and takes typing without pulling the editor out of focus. The glass is drawn by the
// panel's SwiftUI chrome (section 6.1), which turns solid under Reduce Transparency.
import AppKit
import CadenceCore
import CadenceUI
import OSLog
import SwiftUI

@MainActor
final class PanelController {
    /// A borderless panel that can still become key, so the log field takes typing.
    private final class Window: NSPanel {
        /// The top edge stays under the menu bar while SwiftUI changes the height.
        var top: CGFloat?
        var onCancel: (() -> Void)?

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            var frame = frameRect
            if let top { frame.origin.y = top - frame.height }
            super.setFrame(frame, display: flag)
        }

        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }
    }

    private static let signposter = OSSignposter(subsystem: "in.ashwingopalsamy.cadence", category: "panel")
    private static let log = Logger(subsystem: "in.ashwingopalsamy.cadence", category: "panel")

    private let app: AppState
    private let session = PanelSession()
    private let window: Window
    private var monitors: [Any] = []
    /// The status item's window: a click there is the item's own toggle, not a click outside.
    private weak var anchorWindow: NSWindow?

    /// Told when the panel opens or closes, for the status item's highlight and the store poll.
    var onVisibilityChange: ((Bool) -> Void)?
    /// How long the last open took, from the click to the panel on screen, in milliseconds.
    private(set) var lastOpenMilliseconds: Double?

    var isOpen: Bool { window.isVisible }

    init(app: AppState, pause: CapturePause, actions: PanelActions, tempo: (@MainActor (DayStory) -> AnyView)? = nil) {
        self.app = app
        window = Window(
            contentRect: NSRect(x: 0, y: 0, width: CadenceSize.panelWidth, height: CadenceSize.panelWidth),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .popUpMenu
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.setAccessibilityLabel(String(localized: "Cadence panel"))

        let hosting = NSHostingController(
            rootView: PanelView(app: app, pause: pause, session: session, actions: actions, tempo: tempo) { [weak self] in
                self?.close()
            })
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.wantsLayer = true
        window.contentViewController = hosting
        window.onCancel = { [weak self] in self?.close() }
        // Warm: lay out once now, so the first open draws what is already built.
        window.setContentSize(hosting.view.fittingSize)
        window.layoutIfNeeded()
    }

    func toggle(below button: NSStatusBarButton) {
        if isOpen { close() } else { open(below: button) }
    }

    func open(below button: NSStatusBarButton) {
        guard !isOpen, let anchor = button.window else { return }
        let start = CACurrentMediaTime()
        let state = Self.signposter.beginInterval("open")
        anchorWindow = anchor
        let item = anchor.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (anchor.screen ?? NSScreen.main)?.visibleFrame ?? item
        let size = window.frame.size
        let margin = CadenceSpace.s8
        let x = min(max(item.midX - size.width / 2, screen.minX + margin), screen.maxX - size.width - margin)
        let top = item.minY - CadenceSpace.s4
        window.top = top
        window.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: false)
        window.makeKeyAndOrderFront(nil)
        session.opened()
        window.displayIfNeeded()
        lastOpenMilliseconds = (CACurrentMediaTime() - start) * 1000
        Self.signposter.endInterval("open", state)
        Self.log.debug("panel open \(self.lastOpenMilliseconds ?? 0, format: .fixed(precision: 1)) ms")
        startMonitors()
        onVisibilityChange?(true)
    }

    /// Closes the panel and writes a tick still waiting for Undo.
    func close() {
        guard isOpen else { return }
        stopMonitors()
        window.orderOut(nil)
        window.top = nil
        onVisibilityChange?(false)
        Task { await app.flushPendingTick() }
    }

    /// A click in another app, or in one of ours outside the panel and the status item, closes it.
    private func startMonitors() {
        stopMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window !== self.window, event.window !== self.anchorWindow { self.close() }
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func stopMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}
