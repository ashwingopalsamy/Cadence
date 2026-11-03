// Streak milestones (docs/SPEC.md sections 5.4 and 5.6): at 5, 10, 20, 50, 100 and 200 workdays the milestone sound
// plays once. Which milestones have played is kept on this Mac, so reopening Insights, relaunching or a later run that
// reaches the same milestone again never plays it twice.
import CadenceCore
import Foundation

/// Where the milestones already played are kept.
public protocol MilestoneStore: AnyObject {
    func played() -> Set<Int>
    func record(_ played: Set<Int>)
}

/// The milestones played, in the app's defaults under a namespaced key.
public final class DefaultsMilestoneStore: MilestoneStore {
    public static let key = "in.ashwingopalsamy.cadence.insights.streakMilestonesPlayed"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func played() -> Set<Int> {
        Set((defaults.array(forKey: Self.key) as? [Int]) ?? [])
    }

    public func record(_ played: Set<Int>) {
        defaults.set(played.sorted(), forKey: Self.key)
    }
}

/// Plays `.streakMilestone` once for each milestone the streak reaches. When a streak first seen already passes several
/// milestones, the sound plays once and every one of them is marked as played.
@MainActor
public final class MilestoneTracker {
    private let store: any MilestoneStore
    private let play: @MainActor (CadenceSound) -> Void

    public init(store: any MilestoneStore, play: @escaping @MainActor (CadenceSound) -> Void) {
        self.store = store
        self.play = play
    }

    public convenience init(player: CadenceSoundPlayer, store: any MilestoneStore = DefaultsMilestoneStore()) {
        self.init(store: store) { sound in player.play(sound) }
    }

    /// Reads a streak. Returns the milestone it played the sound for, or nil when nothing new was reached. A milestone
    /// counts as played whether or not the sound level let it be heard, so turning sound on later never replays it.
    @discardableResult
    public func reached(_ streak: Int) -> Int? {
        let played = store.played()
        let new = StreakRoadFigures.milestones.filter { $0 <= streak && !played.contains($0) }
        guard let highest = new.last else { return nil }
        store.record(played.union(new))
        play(.streakMilestone)
        return highest
    }
}
