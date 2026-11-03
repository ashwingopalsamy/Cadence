// The models behind the window's sections, made once by the app and kept, so a section opens on what it last read
// and reloads in the background (docs/SPEC.md sections 4.6 and 8.2).
import Observation

@MainActor
public final class WindowSections {
    public let recaps: RecapModel?
    public let proof: ProofModel?
    public let log: LogModel?
    public let inbox: InboxModel?
    public let insights: InsightsModel?
    public let milestones: MilestoneTracker?
    /// The Settings switch "Show my streak"; the streak appears only in Insights.
    public var showsStreak = true
    /// Made after the services they control exist, so set once at launch.
    public var settings: SettingsModel?
    public var firstRun: FirstRunModel?

    public init(
        recaps: RecapModel? = nil, proof: ProofModel? = nil, log: LogModel? = nil, inbox: InboxModel? = nil,
        insights: InsightsModel? = nil, milestones: MilestoneTracker? = nil
    ) {
        self.insights = insights
        self.milestones = milestones
        self.recaps = recaps
        self.proof = proof
        self.log = log
        self.inbox = inbox
    }
}
