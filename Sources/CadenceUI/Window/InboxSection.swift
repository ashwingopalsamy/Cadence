// Inbox in the window (docs/SPEC.md section 4.6).
import SwiftUI

struct InboxSection: View {
    let model: InboxModel?
    let app: AppState

    var body: some View {
        if let model {
            InboxView(model: model, app: app)
                .onAppear { model.start() }
        } else {
            SectionPlaceholder(title: String(localized: "Inbox"))
        }
    }
}
