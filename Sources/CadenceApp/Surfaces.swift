// Where each surface is opened from. The panel, the status menu, notifications and the window all call through here,
// and each surface fills in its entry once it exists, so nothing needs the others at the moment it is made.
import CadenceCore
import CadenceUI

@MainActor
final class Surfaces {
    var openWindow: (PanelActions.Section) -> Void = { _ in }
    var openPlanSheet: () -> Void = {}
    var openWrapUp: () -> Void = {}
    /// The wrap-up for the last workday, while it is still inside its grace window.
    var wrapUpPrevious: () -> Void = {}
    /// The wrap-up for an earlier day that was reopened.
    var wrapUpDay: (LocalDate) -> Void = { _ in }
    var openRecap: () -> Void = {}
    var openSettings: (PanelActions.Pane) -> Void = { _ in }
    var openCapture: () -> Void = {}
}

/// Everyone who rereads when the store changes: the day, and the sections that keep their own reads.
@MainActor
final class StoreChanges {
    private var readers: [() -> Void] = []

    func add(_ reader: @escaping () -> Void) { readers.append(reader) }

    func changed() { readers.forEach { $0() } }
}
