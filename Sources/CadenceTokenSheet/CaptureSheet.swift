// The capture bar in the states a review needs: empty, a parsed line with its chips, the duplicate offer and the
// empty-input message. ACME data and a fixed clock, so every render is the same.
import CadenceCore
import CadenceUI
import Foundation
import SwiftUI

@MainActor
struct CaptureSheet: View {
    private enum Layout {
        static let width: CGFloat = 760
    }

    struct Specimen: Identifiable {
        let id: String
        let title: String
        let model: CaptureBarModel
    }

    let dark: Bool
    let specimens: [Specimen]

    init(dark: Bool) {
        self.dark = dark
        specimens = Self.make()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s8) {
            Text("Capture bar, \(dark ? "dark" : "light")")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
                .padding(.horizontal, CadenceSpace.s24)
            ForEach(specimens) { specimen in
                Text(specimen.title)
                    .cadenceType(CadenceType.label)
                    .foregroundStyle(CadenceColor.ink3.color)
                    .padding(.horizontal, CadenceSpace.s24)
                    .padding(.top, CadenceSpace.s16)
                CaptureBarView(model: specimen.model)
                    .padding(.horizontal, CadenceSpace.s24)
            }
        }
        .padding(.vertical, CadenceSpace.s24)
        .frame(width: Layout.width, alignment: .leading)
        .background(CadenceColor.canvas.color)
    }

    // MARK: Fixtures

    /// Thursday 29 Oct 2026, 15:42 in Kolkata.
    static let now = Date(timeIntervalSince1970: 1_793_268_720)

    static func context() -> CaptureContext {
        CaptureAdapter.context(config: Config.defaults(timezone: "Asia/Kolkata"), now: now)
    }

    static let merge = Entry(
        id: "01JBACME000000000000000001", day: "2026-10-29", kind: .prMerged, family: .delivery,
        title: "Retry fix for the capture path", occurredAt: "2026-10-29T14:31:00+05:30",
        ticket: Ticket(key: "ACME-4821", class: .assigned), origin: .collected, source: "github")

    static func model(_ text: String, found: [Entry] = []) -> CaptureBarModel {
        let model = CaptureBarModel(
            environment: CaptureBarModel.Environment(
                context: { context() }, found: { found }, save: { _ in .failed(StoreFailure(detail: "")) }))
        model.draft = CaptureDraft(text: text)
        return model
    }

    static func make() -> [Specimen] {
        let empty = model("")
        let parsed = model("Reviewed 3 PRs for ACME-4821 @14:30 ~45m #payments")
        parsed.focusedChip = 2
        let duplicate = model("merged ACME-4821 retry fix @14:30", found: [merge])
        let blank = model("")
        Task { await blank.submit(keepOpen: false) }
        return [
            Specimen(id: "empty", title: "Empty", model: empty),
            Specimen(id: "parsed", title: "A parsed line, the ticket chip focused", model: parsed),
            Specimen(id: "duplicate", title: "The duplicate offer", model: duplicate),
            Specimen(id: "blank", title: "Empty input", model: blank),
        ]
    }
}
