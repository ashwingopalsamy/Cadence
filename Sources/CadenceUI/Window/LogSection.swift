// Log in the window (docs/SPEC.md section 4.6).
import SwiftUI

struct LogSection: View {
    let model: LogModel?
    let app: AppState
    let navigation: WindowNavigation

    var body: some View {
        if let model {
            LogView(model: model, app: app, navigation: navigation)
                .onAppear { model.start() }
        } else {
            SectionPlaceholder(title: String(localized: "Log"))
        }
    }
}
