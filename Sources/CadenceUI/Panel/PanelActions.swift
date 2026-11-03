// What the panel and the status item's menu hand to the rest of the app (docs/SPEC.md sections 4.1 and 4.2).
// Ticks, logging, days off, working after all and resume go straight through AppState; everything that opens
// another surface goes through one of these closures, so the window, the sheets and the capture bar are wired by
// whoever builds them.
import Foundation

@MainActor
public struct PanelActions {
    /// A section of the window.
    public enum Section: Sendable, Equatable {
        case today
        case insights
    }

    /// A pane of Settings.
    public enum Pane: Sendable, Equatable {
        case general
        case sources
    }

    /// Opens the window on a section, bringing the app forward.
    public var openWindow: (Section) -> Void
    /// The morning plan sheet (section 4.4).
    public var openPlanSheet: () -> Void
    /// The wrap-up sheet (section 4.5).
    public var openWrapUp: () -> Void
    /// Last week's recap (section 5.5).
    public var openRecap: () -> Void
    public var openSettings: (Pane) -> Void
    /// Seals today with nothing logged.
    public var sealAsEmpty: () -> Void
    /// The capture bar, `⌃⌥L` (section 4.3).
    public var openCapture: () -> Void

    public init(
        openWindow: @escaping (Section) -> Void = { _ in },
        openPlanSheet: @escaping () -> Void = {},
        openWrapUp: @escaping () -> Void = {},
        openRecap: @escaping () -> Void = {},
        openSettings: @escaping (Pane) -> Void = { _ in },
        sealAsEmpty: @escaping () -> Void = {},
        openCapture: @escaping () -> Void = {}
    ) {
        self.openWindow = openWindow
        self.openPlanSheet = openPlanSheet
        self.openWrapUp = openWrapUp
        self.openRecap = openRecap
        self.openSettings = openSettings
        self.sealAsEmpty = sealAsEmpty
        self.openCapture = openCapture
    }

    /// Runs the panel's one action.
    public func run(_ action: PanelAction) {
        switch action {
        case .fix, .finishSetup: openWindow(.today)
        case .planDay, .planToday: openPlanSheet()
        case .wrapUp: openWrapUp()
        case .sealAsEmpty: sealAsEmpty()
        case .lastWeekRecap: openRecap()
        }
    }
}
