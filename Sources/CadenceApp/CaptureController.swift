// The capture bar's window (docs/SPEC.md sections 4.3 and 6.1): a floating panel that takes the keyboard without
// bringing Cadence forward, centred on the screen you are working on. It is built once at launch and only shown
// and hidden after that, so it opens at once. A save that fails keeps the line and shows why.
import AppKit
import CadenceCore
import CadenceUI
import SwiftUI

@MainActor
final class CaptureController: NSObject, NSWindowDelegate {
    /// Room around the bar for its floating shadow (`CadenceShadow.floating`: radius 28, offset 18).
    private static let shadowMargin = CadenceSpace.s48

    private let state: AppState
    private let location: StoreLocation
    private let clock: any CadenceCore.Clock
    private let panel: CapturePanel
    private var model: CaptureBarModel!
    private var hosting: SizedHostingView<AnyView>!
    /// Where the bar's top edge sits while it is open, so chips and offers grow it downward only.
    private var top: CGFloat?

    /// `icon` draws the app icon in the bar's 26-point slot (T3.6 wires `TempoAppIcon` here).
    init(state: AppState, location: StoreLocation, clock: any CadenceCore.Clock, icon: (() -> AnyView)? = nil) {
        self.state = state
        self.location = location
        self.clock = clock
        panel = CapturePanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered,
            defer: false)
        super.init()

        model = CaptureBarModel(
            environment: CaptureBarModel.Environment(
                context: { [unowned self] in self.parserContext() },
                found: { [unowned self] in self.state.context?.found ?? [] },
                save: { [unowned self] request in await self.save(request) },
                lastEntry: { [unowned self] in self.state.context?.found.last { $0.origin == .selfReported } },
                dismiss: { [unowned self] entry in await self.state.setStatus(entry.id, to: .dismissed) },
                close: { [unowned self] in self.close() },
                discreet: { [unowned self] in self.state.discreet }))

        let root = CaptureBarView(model: model, icon: icon).padding(Self.shadowMargin)
        hosting = SizedHostingView(rootView: AnyView(root))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onResize = { [weak self] in self?.fit() }

        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.setAccessibilityLabel(String(localized: "Capture"))
        panel.delegate = self
    }

    var isOpen: Bool { panel.isVisible }

    /// `⌃⌥L` opens the bar; `⌃⌥N` opens it with the kind set to note. Opening it again while open switches the mode.
    func open(_ mode: CaptureBarModel.Mode) {
        model.open(mode)
        top = nil
        fit()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            let curve = CadenceMotion.ease
            context.duration = CadenceMotion.open.duration
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        top = nil
    }

    // A click anywhere else closes the bar, as Spotlight does. The line stays only when its save failed.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: Parts

    private func save(_ request: LogRequest) async -> CaptureSaveOutcome {
        if case .entry(let entry)? = await state.perform(.log(request)) { return .saved(entry) }
        return .failed(state.issue ?? StoreFailure(kind: .other, summary: String(localized: "Cadence could not save that"), detail: ""))
    }

    /// The same zone, day boundary and ticket rules `cadence log` uses, read fresh each time the bar opens.
    private func parserContext() -> CaptureContext {
        let fallbackZone = TimeZone.current.identifier
        var config = Config.defaults(timezone: fallbackZone)
        if case .found(let roots) = location, let loaded = try? ConfigStore.load(from: roots.config, fallbackZone: fallbackZone) {
            config = loaded.0
        }
        return CaptureAdapter.context(config: config, now: clock.now())
    }

    /// Sizes the panel to the bar. The first fit centres it on the screen under the pointer; later fits keep the top.
    private func fit() {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let topEdge = top ?? (visible.midY + size.height / 2)
        top = topEdge
        let x = panel.isVisible ? panel.frame.minX : visible.midX - size.width / 2
        panel.setFrame(NSRect(x: x, y: topEdge - size.height, width: size.width, height: size.height), display: true)
    }
}

/// A borderless panel that still takes the keyboard.
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Tells its owner when the bar's size changes, so the panel follows it.
final class SizedHostingView<Content: View>: NSHostingView<Content> {
    var onResize: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
}
