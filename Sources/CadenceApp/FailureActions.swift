// What each failure action does on the Mac (docs/SPEC.md section 4.6, T3.33). Nothing here writes to the store, and
// nothing falls back to another location: every action shows, copies or explains.
import AppKit
import CadenceCore
import CadenceUI

@MainActor
enum FailureActions {
    static func perform(_ action: FailureCopy.Action, app: AppState, location: StoreLocation, openSettings: (String) -> Void) {
        switch action {
        case .copyText:
            guard let text = app.unsavedText else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .showFolder:
            if case .found(let roots) = location { NSWorkspace.shared.activateFileViewerSelecting([roots.home]) }
        case .showDamagedFile:
            if case .found(let roots) = location { NSWorkspace.shared.activateFileViewerSelecting([roots.database]) }
        case .runDoctor:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("cadence doctor", forType: .string)
            explain(
                String(localized: "cadence doctor is copied."),
                String(localized: "Paste it in Terminal. It checks the store, the hooks and the agent, and changes nothing."))
        case .updateSteps:
            explain(
                String(localized: "Update the app and the command-line tool together."),
                String(localized: "From your Cadence checkout, run make install, then open Cadence again. Your log is not touched."))
        case .restoreBackup:
            openSettings("Data")
        case .tryAgain:
            app.model.reload()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private static func explain(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
