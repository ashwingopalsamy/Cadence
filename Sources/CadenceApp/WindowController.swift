// The one window (docs/SPEC.md section 4.6): a unified toolbar that SwiftUI fills, a frame that is remembered between
// launches, and a way in from the panel and notifications. The app stays an accessory app; opening the window only
// brings it forward.
import AppKit
import CadenceUI
import SwiftUI

@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    let navigation: WindowNavigation
    private let app: AppState
    private let actions: WindowActions
    private let sections: WindowSections
    private var window: NSWindow?

    private enum Layout {
        static let autosaveName = "CadenceWindow"
        /// The first size, before any frame is remembered: the full layout.
        static let initial = NSSize(width: 1100, height: 760)
        /// Below 480 wide the window uses its compact layout; it goes no narrower than this.
        static let minimum = NSSize(width: 360, height: 480)
    }

    init(app: AppState, actions: WindowActions, sections: WindowSections, navigation: WindowNavigation = WindowNavigation()) {
        self.navigation = navigation
        self.sections = sections
        self.app = app
        self.actions = actions
        super.init()
    }

    /// Shows the window at a section and brings the app forward.
    func open(section: WindowSection) {
        if section == .settings {
            navigation.openSettings(pane: nil)
        } else {
            navigation.open(section)
        }
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let root = WindowRoot(app: app, navigation: navigation, actions: actions, sections: sections)
        let host = NSHostingController(rootView: root)
        // SwiftUI's toolbar items become the window's own toolbar.
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.initial),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.contentViewController = host
        window.title = String(localized: "Cadence")
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = Layout.minimum
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(Layout.initial)
        if !window.setFrameUsingName(Layout.autosaveName) { window.center() }
        window.setFrameAutosaveName(Layout.autosaveName)
        return window
    }

    /// A tick waiting for Undo is written when the window closes, as when the panel closes.
    func windowWillClose(_ notification: Notification) {
        Task { await app.flushPendingTick() }
    }
}
