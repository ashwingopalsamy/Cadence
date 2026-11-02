// Where each part of the day ring goes (docs/SPEC.md section 5.2). Pure, so the geometry can be tested.
import CadenceCore
import Foundation

public struct DayRingLayout: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var status: TaskStatus
        public var start: CGFloat
        public var end: CGFloat
    }

    public struct Bead: Sendable, Equatable {
        public var family: Family
        public var angle: CGFloat
    }

    public var segments: [Segment]
    public var beads: [Bead]

    /// A task carried to another day has left this one, so it has no segment.
    public init(tasks: [TaskStatus], beads counts: [Family: Int]) {
        let tokens = CadenceRingTokens.self
        let kept = tasks.filter { $0 != .moved }
        let n = CGFloat(kept.count)
        let span = n > 0 ? (360 - tokens.topGap - (n - 1) * tokens.segmentGap) / n : 0
        segments = kept.enumerated().map { index, status in
            let start = tokens.topGap / 2 + CGFloat(index) * (span + tokens.segmentGap)
            return Segment(status: status, start: start, end: start + span)
        }

        var list: [Family] = []
        for family in Family.ringOrder {
            let limit = family == .ai ? tokens.aiBeads : tokens.beadsPerFamily
            list += Array(repeating: family, count: min(counts[family] ?? 0, limit))
        }
        let groups = Set(list).count
        var (step, familyGap) = (tokens.beadStep, tokens.beadFamilyGap)
        let need = CGFloat(list.count) * step + CGFloat(max(0, groups - 1)) * familyGap
        if need > tokens.beadSweep {
            let fit = tokens.beadSweep / need
            step *= fit
            familyGap *= fit
        }
        var angle = tokens.beadStart
        var previous: Family?
        beads = list.map { family in
            if let previous, previous != family { angle += familyGap }
            defer {
                angle += step
                previous = family
            }
            return Bead(family: family, angle: angle)
        }
    }
}
