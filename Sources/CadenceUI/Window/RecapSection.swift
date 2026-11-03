// Recap in the window (docs/SPEC.md sections 4.6 and 5.5).
import SwiftUI

struct RecapSection: View {
    let model: RecapModel?
    let discreet: Bool

    var body: some View {
        if let model {
            RecapView(model: model, discreet: discreet)
                .onAppear { model.reload() }
        } else {
            SectionPlaceholder(title: String(localized: "Recap"))
        }
    }
}
