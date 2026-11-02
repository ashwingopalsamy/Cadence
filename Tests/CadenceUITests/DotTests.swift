import AppKit
import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

@Suite struct DotTests {
    static let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    static let start = Date(timeIntervalSince1970: 1_793_000_000)

    static func appearance(_ state: DotState) -> DotAppearance {
        switch state {
        case .dayStarted: DotAppearance(state: state, startedAt: start)
        case .inProgress, .agentLogged, .wrapUpDue: DotAppearance(state: state, progress: 0.6, resolved: 3, planned: 5)
        case .sealed: DotAppearance(state: state, progress: 1, resolved: 5, planned: 5, streak: 19)
        case .onCall: DotAppearance(state: state, onCall: true)
        default: DotAppearance(state: state)
        }
    }

    @Test func everyStateSaysWhatTheSpecSays() {
        let locale = Locale(identifier: "en_GB")
        let expected: [DotState: String] = [
            .resting: "Cadence, day not started", .planPending: "Plan your day", .inProgress: "3 of 5 planned done",
            .wrapUpDue: "Wrap-up due", .sealed: "Day sealed, streak 19", .onCall: "On call", .leave: "On leave",
            .paused: "Capture paused", .needsAttention: "Cadence needs attention", .agentLogged: "An agent logged work",
        ]
        for (state, label) in expected {
            #expect(Self.appearance(state).accessibilityLabel(locale: locale, timeZone: Self.kolkata) == label)
        }
        let started = Self.appearance(.dayStarted).accessibilityLabel(locale: locale, timeZone: Self.kolkata)
        #expect(started.hasPrefix("Day started at "))
        #expect(started.contains(":"))
    }

    @Test func noLabelUsesADash() {
        for state in DotState.allCases {
            let label = Self.appearance(state).accessibilityLabel()
            #expect(!label.contains("\u{2013}") && !label.contains("\u{2014}"))
        }
    }

    @Test func unknownStaysUnsaid() {
        #expect(DotAppearance(state: .sealed).accessibilityLabel() == "Day sealed")
        #expect(DotAppearance(state: .dayStarted).accessibilityLabel() == "Day started")
    }

    @Test func onCallIsSaidAfterTheRestAndAddsTheOuterRing() {
        let busy = DotAppearance(state: .inProgress, progress: 0.6, onCall: true, resolved: 3, planned: 5)
        #expect(busy.accessibilityLabel() == "3 of 5 planned done, on call")
        #expect(DotPose(busy).outer == 1)
        #expect(DotPose(Self.appearance(.onCall)).outer == 1)
        #expect(DotPose(Self.appearance(.inProgress)).outer == 0)
    }

    @Test func anErrorOutranksEverythingAndLoadingRests() {
        let failed = DotAppearance(load: .failed(StoreFailure(detail: "x")), signals: DotSignals(paused: true, wrapUpDue: true))
        #expect(failed.state == .needsAttention)
        #expect(DotAppearance(load: .loading).state == .resting)
    }

    @Test func everyStateHasItsOwnForm() {
        // Agent logged rests in the wrap-up form: the spec tells them apart by its one orbit, and it does not last.
        var seen: [Data] = []
        for state in DotState.allCases where state != .agentLogged {
            let image = DotRenderer.image(DotPose(Self.appearance(state)))
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: CadenceDotTokens.glyph, height: CadenceDotTokens.glyph))
            let data = image.tiffRepresentation ?? Data()
            #expect(!data.isEmpty)
            #expect(!seen.contains(data), "\(state) looks like another state")
            seen.append(data)
        }
    }

    @Test func increaseContrastThickensStrokes() {
        let pose = DotPose(Self.appearance(.resting))
        #expect(DotRenderer.image(pose).tiffRepresentation != DotRenderer.image(pose, highContrast: true).tiffRepresentation)
    }

    @Test func reduceMotionRemovesEveryAnimation() {
        for from in DotState.allCases {
            for to in DotState.allCases {
                #expect(DotMotion.between(Self.appearance(from), Self.appearance(to), reduceMotion: true) == .instant)
            }
        }
    }

    @Test func motionFollowsTheTable() {
        func motion(_ from: DotState, _ to: DotState) -> DotMotion {
            DotMotion.between(Self.appearance(from), Self.appearance(to), reduceMotion: false)
        }
        #expect(motion(.resting, .dayStarted).duration == 0.24)
        #expect(motion(.resting, .dayStarted).curve == .spring)
        #expect(motion(.dayStarted, .planPending).duration == 0.18)
        #expect(motion(.inProgress, .agentLogged).duration == 0.7)
        #expect(motion(.inProgress, .agentLogged).orbits)
        #expect(motion(.inProgress, .wrapUpDue).pulses)
        #expect(motion(.inProgress, .sealed).duration == 0.4)
        #expect(motion(.dayStarted, .leave) == .instant)
        let moved = DotMotion.between(
            DotAppearance(state: .inProgress, progress: 0.2), DotAppearance(state: .inProgress, progress: 0.4), reduceMotion: false)
        #expect(moved.duration == 0.4)
    }

    @Test func aMotionEndsExactlyOnItsTarget() {
        let from = DotPose(Self.appearance(.dayStarted))
        let to = DotPose(Self.appearance(.sealed))
        let motion = DotMotion.between(Self.appearance(.dayStarted), Self.appearance(.sealed), reduceMotion: false)
        #expect(motion.pose(from: from, to: to, at: motion.duration) == to)
        #expect(motion.pose(from: from, to: to, at: 0) == from)
    }

    @Test func curvesStartAtZeroAndSettleOnOne() {
        #expect(CadenceMotion.easeProgress(0) == 0)
        #expect(CadenceMotion.easeProgress(1) == 1)
        #expect(CadenceMotion.easeProgress(0.5) > 0.5)
        #expect(abs(CadenceMotion.springProgress(elapsed: 0)) < 0.0001)
        #expect(abs(CadenceMotion.springProgress(elapsed: 5) - 1) < 0.0001)
        let overshoots = stride(from: 0.0, to: 1, by: 0.01).contains { CadenceMotion.springProgress(elapsed: $0) > 1 }
        #expect(overshoots)
    }
}
