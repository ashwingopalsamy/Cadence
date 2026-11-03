// Insights in the window (docs/SPEC.md sections 4.6 and 5.4).
import SwiftUI

struct InsightsSection: View {
    let model: InsightsModel?
    let milestones: MilestoneTracker?
    let showsStreak: Bool
    let showsTempo: Bool

    var body: some View {
        if let model {
            InsightsView(model: model, showsStreak: showsStreak, showsTempo: showsTempo, milestones: milestones, scrolls: false)
                .onAppear { model.refresh() }
        } else {
            SectionPlaceholder(title: String(localized: "Insights"))
        }
    }
}
