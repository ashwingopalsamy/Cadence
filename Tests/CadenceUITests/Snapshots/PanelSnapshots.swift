// The menu-bar panel in every row of its table (docs/SPEC.md section 4.2), on the solid Reduce Transparency ground,
// since a render has nothing behind the glass, and without the window's shadow, which belongs to the window and which
// the software renderer takes a second to blur. The panel holds a text field, so it is drawn in a hosted view.
import SwiftUI
import Testing

@testable import CadenceUI

extension Snapshots {
    @Suite("the panel") struct Panel {
        @MainActor @Test(arguments: PanelSpecimens.samples.map { Named(name: $0.name, value: $0) }) func panel(_ item: Named<PanelSpecimens.Sample>) {
            Snapshot.check("panel", Snapshot.slug(item.name), path: .hosting, margin: CadenceSpace.s24) {
                PanelCard(content: PanelContent(item.value.input, locale: Snapshot.locale), solid: true)
            }
        }
    }
}
