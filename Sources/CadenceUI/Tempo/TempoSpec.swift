// Tempo is composed from the day, never looked up (docs/SPEC.md section 5.3). A state picks a pose, then the day's
// own numbers adapt it: the water is plan progress, the walking poses keep the pace of the count against usual by now,
// and the time of day changes what Tempo does. This mirrors the approved prototype's `tempoFor`.
import CadenceCore
import Foundation

public struct TempoSpec: Sendable, Hashable {
    public var name: TempoPose.Name
    /// The water, 0 to 1.
    public var level: Double
    /// Milliseconds per beat.
    public var period: Int
    public var surface: TempoPose.Surface
    /// Bubbles rising through the water on a lively day, 0 to 3.
    public var bubbles: Int

    public var pose: TempoPose { TempoPose.named(name) }

    /// A pose by name, for recaps, first run and other moments. The level defaults to the pose's own.
    public init(pose name: TempoPose.Name, level: Double? = nil) {
        let pose = TempoPose.named(name)
        self.name = name
        self.level = min(1, max(0, level ?? pose.level))
        self.period = pose.period ?? CadenceTempoTokens.Motion.defaultPeriod
        self.surface = pose.surface ?? .wave
        self.bubbles = pose.surface == .choppy ? 2 : 0
    }

    /// The count against usual by now, which sets the walking poses' pace.
    public struct Pace: Sendable, Equatable {
        public var items: Int
        /// Usual by now, low to high. Nil when there is no range, which reads as in rhythm.
        public var usualByNow: ClosedRange<Int>?

        public init(items: Int, usualByNow: ClosedRange<Int>?) {
            self.items = items
            self.usualByNow = usualByNow
        }

        public init(_ input: DayStory.Input) {
            self.init(items: input.items, usualByNow: input.usualByNow)
        }

        /// Items above the bracket's high, when positive.
        var over: Int { usualByNow.map { items - $0.upperBound } ?? 0 }
        /// Items below the bracket's low, when positive.
        var under: Int { usualByNow.map { $0.lowerBound - items } ?? 0 }
    }

    /// The poses whose beat follows the count.
    static let walkers: Set<TempoPose.Name> = [.walk, .brisk, .mug, .lantern]

    /// Tempo for this day. `hour` is the local hour, 0 to 23. `pace` defaults to the input's own items and usual by now.
    public static func compose(state: DayStory.State, input: DayStory.Input, hour: Int, pace: Pace? = nil) -> TempoSpec {
        var name = TempoPose.name(for: state)
        if state == .morning, hour >= CadenceTempoTokens.ponderHour { name = .ponder }
        if state == .fewerThanUsual, hour >= CadenceTempoTokens.lanternHour { name = .lantern }
        if input.planned > 0, input.resolved >= input.planned, input.sealedAt == nil, !keepsItsPose(state) { name = .tada }

        let pose = TempoPose.named(name)
        var spec = TempoSpec(pose: name)
        if input.sealedAt != nil {
            spec.level = 1
        } else if input.planned > 0 {
            spec.level = min(1, Double(max(0, input.resolved)) / Double(input.planned))
        } else if state == .firstSync, let i = input.importing {
            spec.level = i.total > 0 ? min(1, max(0, Double(i.done) / Double(i.total))) : 0
        } else {
            spec.level = pose.level
        }

        if walkers.contains(name) {
            // Pace follows the count against your usual range: never a reward, only a tempo.
            let pace = pace ?? Pace(input)
            let (over, under) = (pace.over, pace.under)
            let p = CadenceTempoTokens.Pace.self
            spec.period =
                over > 0
                ? max(p.briskFloor, p.briskBase - over * p.briskStep)
                : under > 0 ? min(p.slowCeiling, p.slowBase + under * p.slowStep) : p.rhythmBase + (hour - p.rhythmNoon) * p.rhythmStep
            spec.surface = over > 0 ? .choppy : under > 0 ? .calm : .wave
            spec.bubbles = over > 0 ? min(p.bubbleCap, over) : 0
            if name == .walk, over > 0 { spec.name = .brisk }
            if name == .brisk, over <= 0 { spec.name = .walk }
        }
        return spec
    }

    /// Days off, errors and days already settled or sealed keep their own pose when the plan is all resolved.
    static func keepsItsPose(_ state: DayStory.State) -> Bool {
        switch state {
        case .leave, .sick, .holiday, .weekend, .storeProblem, .planSettled, .sealed, .editedAfterWrapUp: true
        default: false
        }
    }

    // MARK: Motion

    /// Whether the pose has a gesture to play.
    public var moves: Bool { pose.gesture != nil }

    /// Seconds per beat.
    var beat: TimeInterval { TimeInterval(period) / 1000 }

    /// The gesture's length: 8 swings of two beats each, as the prototype's 8 iterations of a two-beat cycle.
    public var gestureDuration: TimeInterval { moves ? beat * 2 * Double(CadenceMotion.tempoBeats) : 0 }

    /// Whether bubbles rise while the gesture plays: a lively day, and enough water to rise through.
    var showsBubbles: Bool { moves && bubbles > 0 && level > CadenceTempoTokens.Motion.bubbleLevel }

    /// How long anything moves after the view appears or the spec changes. After this Tempo holds still.
    public var playDuration: TimeInterval {
        guard moves else { return 0 }
        let m = CadenceTempoTokens.Motion.self
        let lastBubble = showsBubbles ? TempoGeometry.bubbles.prefix(bubbles).map(\.delay).max() ?? 0 : 0
        let rising = showsBubbles ? lastBubble + m.bubbleRise * Double(m.bubbleRises) : 0
        return max(gestureDuration, rising)
    }
}
