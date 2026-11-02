// The status item: an AppKit item of fixed length, not MenuBarExtra, which cannot do right-click menus, drops or
// custom animation (docs/SPEC.md section 4.1). A display link runs only during a motion, so the idle dot costs nothing.
import AppKit
import CadenceUI
import Observation

@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: CadenceDotTokens.itemLength)
    private let model: DayModel
    private var signals = DotSignals()
    private var current: DotAppearance?
    private var fromPose: DotPose?
    private var toPose: DotPose?
    private var motion = DotMotion.instant
    private var motionStart: CFTimeInterval = 0
    private var link: CADisplayLink?
    private let menu = NSMenu()

    init(model: DayModel) {
        self.model = model
        super.init()
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        observe()
    }

    /// Re-arms itself: Observation fires once per change.
    private func observe() {
        let next = withObservationTracking {
            DotAppearance(load: model.load, signals: signals)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(next)
    }

    private var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    private func apply(_ next: DotAppearance) {
        guard next != current else { return }
        let previous = current
        current = next
        let target = DotPose(next)
        let label = next.accessibilityLabel()
        item.button?.setAccessibilityLabel(label)

        guard let previous else {
            // The first state at launch appears; there is nothing to move from.
            show(target)
            return
        }
        announce(label, from: previous, to: next)
        if next.state == .sealed, previous.state != .sealed {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        let motion = DotMotion.between(
            previous, next, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard motion.duration > 0, let button = item.button else {
            stopLink()
            show(target)
            return
        }
        fromPose = toPose ?? DotPose(previous)
        toPose = target
        self.motion = motion
        motionStart = CACurrentMediaTime()
        if link == nil {
            let link = button.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick() {
        guard let fromPose, let toPose else { return stopLink() }
        let elapsed = CACurrentMediaTime() - motionStart
        draw(motion.pose(from: fromPose, to: toPose, at: elapsed))
        if elapsed >= motion.duration { stopLink() }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private func show(_ pose: DotPose) {
        toPose = pose
        draw(pose)
    }

    private func draw(_ pose: DotPose) {
        item.button?.image = DotRenderer.image(pose, highContrast: highContrast)
    }

    /// Changes are announced politely, and only when the words changed.
    private func announce(_ label: String, from previous: DotAppearance, to next: DotAppearance) {
        guard previous.accessibilityLabel() != label, let button = item.button else { return }
        NSAccessibility.post(
            element: button, notification: .announcementRequested,
            userInfo: [.announcement: label, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    @objc private func displayOptionsChanged() {
        if let toPose { draw(toPose) }
    }
}
