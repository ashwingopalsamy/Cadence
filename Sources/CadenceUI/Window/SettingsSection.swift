// Settings in the window (docs/SPEC.md section 4.6).
import SwiftUI

struct SettingsSection: View {
    let model: SettingsModel?
    let pane: String?
    let showsTempo: Bool

    var body: some View {
        if let model {
            SettingsView(model: model, showsTempo: showsTempo)
                .onAppear { if let pane, let chosen = SettingsPane(rawValue: pane) { model.pane = chosen } }
                .onChange(of: pane) { _, new in if let new, let chosen = SettingsPane(rawValue: new) { model.pane = chosen } }
        } else {
            SectionPlaceholder(title: String(localized: "Settings"))
        }
    }
}
