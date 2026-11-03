// Proof in the window (docs/SPEC.md sections 4.6 and 12).
import SwiftUI

struct ProofSection: View {
    let model: ProofModel?
    let discreet: Bool
    let openSources: () -> Void

    var body: some View {
        if let model {
            ProofView(model: model, discreet: discreet, openSources: openSources)
        } else {
            SectionPlaceholder(title: String(localized: "Proof"))
        }
    }
}
