// Tempo in every pose of docs/SPEC.md section 5.3 at 96 pt, held. The held pose is what Tempo shows once its gesture
// has played, or at once under Reduce Motion, so no render catches a gesture halfway.
import SwiftUI
import Testing

@testable import CadenceUI

extension Snapshots {
    @Suite("Tempo") struct Tempo {
        static let size: CGFloat = 96

        @MainActor @Test func everyPoseIsDrawn() {
            #expect(Set(TempoPose.all.map { Snapshot.slug($0.name.rawValue, camelCase: true) }).count == TempoPose.all.count, "a file name is used twice")
        }

        /// The drawing reaches past its box (a wrench, a plug, a body lying down), so the canvas is left room all round.
        @MainActor @Test(arguments: TempoPose.all.map { Named(name: $0.name.rawValue, value: $0) }) func pose(_ item: Named<TempoPose>) {
            Snapshot.check("tempo", Snapshot.slug(item.name, camelCase: true), margin: CadenceSpace.s24) {
                TempoCanvas(spec: TempoSpec(pose: item.value.name), elapsed: nil)
                    .frame(width: Self.size, height: TempoView.height(forWidth: Self.size))
            }
        }
    }
}
