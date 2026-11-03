import AppKit
import CadenceCore
import Foundation
import SwiftUI
import Testing

@testable import CadenceUI

/// Tempo (docs/SPEC.md sections 5.3 and 5.7): every pose of the approved prototype, composed from the day as its
/// `tempoFor` does, never two moments alike, and drawable at every size.
@Suite struct TempoTests {
    static let thursday = LocalDate("2026-10-29")!

    static func input(_ change: (inout DayStory.Input) -> Void = { _ in }) -> DayStory.Input {
        var input = DayStory.Input(date: thursday)
        input.countedWorkdays = 20
        change(&input)
        return input
    }

    /// A day that makes each state true, as DayStory reads it, with a plan still open where a plan fits.
    static func day(for state: DayStory.State) -> DayStory.Input {
        input { d in
            switch state {
            case .storeProblem: d.storeProblem = true
            case .paused: d.paused = true
            case .sealed:
                d.sealedAt = "18:12"
                (d.planned, d.resolved) = (5, 5)
            case .editedAfterWrapUp:
                d.sealedAt = "18:12"
                d.lateAdditions = 1
                (d.planned, d.resolved) = (5, 5)
            case .yesterdayOpen: d.previous = .init(date: LocalDate("2026-10-28")!, graceOpen: true, sealedBefore: 18)
            case .closedUnsealed: d.previous = .init(date: LocalDate("2026-10-28")!, graceOpen: false, sealedBefore: 18)
            case .leave: d.dayOff = .leave
            case .sick: d.dayOff = .sick
            case .holiday: d.dayOff = .holiday
            case .weekend: d.dayOff = .weekend
            case .firstRun: d.firstRun = true
            case .firstSync: d.importing = .init(label: "October", done: 12, total: 20)
            case .learning: d.countedWorkdays = 6
            case .sourceBehind:
                d.behind = .init(source: "GitHub", lastSync: "13:40")
                d.items = 7
            case .onCall:
                d.onCall = true
                d.items = 7
            case .wrapUpDue:
                d.wrapUpReminder = "17:30"
                (d.planned, d.resolved, d.items) = (5, 3, 8)
            case .nothingLogged: d.wrapUpReminder = "17:30"
            case .planSettled: (d.planned, d.resolved, d.items) = (5, 5, 8)
            case .morning: d.carried = 2
            case .planned: d.planned = 4
            case .inRhythm: (d.planned, d.resolved, d.items, d.usualByNow) = (5, 2, 7, 6...8)
            case .moreThanUsual: (d.planned, d.resolved, d.items, d.usualByNow) = (5, 2, 14, 6...8)
            case .fewerThanUsual: (d.planned, d.resolved, d.items, d.usualByNow) = (5, 2, 2, 4...6)
            }
        }
    }

    static let statePose: [DayStory.State: TempoPose.Name] = [
        .firstRun: .hello, .firstSync: .sync, .learning: .learn, .morning: .stretch, .planned: .clipboard, .inRhythm: .walk,
        .moreThanUsual: .brisk, .fewerThanUsual: .mug, .planSettled: .tada, .wrapUpDue: .bell, .sealed: .sleep,
        .editedAfterWrapUp: .peek, .yesterdayOpen: .lookback, .onCall: .headset, .leave: .lounge, .sick: .sick,
        .holiday: .party, .weekend: .read, .paused: .meditate, .sourceBehind: .lookout, .nothingLogged: .shrug,
        .closedUnsealed: .scratch, .storeProblem: .worried,
    ]

    // MARK: Poses

    static let notes: [TempoPose.Name: String] = [
        .hello: "First run: waves hello", .sync: "First sync: waits with an hourglass", .learn: "Still learning: peers closer",
        .stretch: "Morning: stretches and yawns", .ponder: "Late morning: wonders what is first",
        .clipboard: "Planned: points at the list", .walk: "In rhythm: walks on the beat", .brisk: "More than usual: a brisk walk",
        .mug: "Fewer than usual: strolls with a mug", .lantern: "Quiet evening: a lantern", .tada: "Plan settled: ta-da",
        .bell: "Wrap-up due: rings a bell", .sleep: "Sealed: lies down and sleeps", .peek: "Late addition: one eye, one note",
        .lookback: "Yesterday open: looks back at it", .headset: "On call: hand to the earpiece", .lounge: "On leave: feet up",
        .sick: "Off sick: wrapped up warm", .party: "Holiday: party hat", .read: "Weekend: reads a book",
        .meditate: "Paused: sits still and breathes", .lookout: "Source behind: looks into the distance",
        .shrug: "Nothing logged: a gentle shrug", .scratch: "Closed unsealed: scratches its head",
        .worried: "A problem: honest about it", .welcome: "Welcome: arms open", .lock: "Your data: keeps it locked here",
        .plug: "GitHub: plugs in", .laptop: "Claude Code: at the keyboard", .carry: "History: carries October in",
        .raise: "Permissions: asks politely", .reviewer: "Reviews: reads closely", .tick: "Plan: ticks the list",
        .parcel: "Delivered: carries the parcel", .friend: "People: waves to a friend", .chat: "With AI: talks it through",
        .scroll: "Month of plans: a long list", .stack: "Merged: a stack of parcels", .calendar: "Consistency: points at the calendar",
        .metronome: "Steady: keeps time", .stamp: "Proof: stamps it", .twoMugs: "Since your 1:1: two cups",
        .cards: "Reprioritised: reorders the cards", .blanket: "Sealing: tucks in", .broom: "Inbox empty: sweeps up",
        .chart: "Too little data: plots the first dots", .wrench: "Settings: tinkers", .icon: "App icon: Tempo at rest",
        .conduct: "Cadence: keeps the beat",
    ]

    @Test func everyPoseOfThePrototypeIsThereWithItsNote() {
        #expect(TempoPose.all.count == 49)
        #expect(TempoPose.all.map(\.name) == TempoPose.Name.allCases)
        for pose in TempoPose.all {
            #expect(pose.note == Self.notes[pose.name], "\(pose.name)")
            #expect(CopyRules.allows(pose.note), "\(pose.name)")
            #expect((0...1).contains(pose.level), "\(pose.name)")
            #expect((pose.gesture == nil) == (pose.period == nil), "\(pose.name): a gesture has a period")
        }
        #expect(TempoPose.all.filter { $0.moment == .dayState }.count == 25)
        #expect(TempoPose.all.filter { $0.moment == .firstRun }.map(\.name) == TempoPose.onboarding)
        #expect(TempoPose.all.filter { $0.moment == .recap }.count == 12)
        #expect(TempoPose.all.filter { $0.moment == .other }.count == 6)
    }

    @Test func posesKeepThePrototypesFields() {
        let sync = TempoPose.named(.sync)
        #expect(sync.left == .init(-36, -58, front: true) && sync.front == .hourglass && sync.legs == .sit)
        #expect(sync.surface == .dotted && sync.period == 1100 && sync.level == 0.3 && sync.gesture?.body == .breathe)
        let learn = TempoPose.named(.learn)
        #expect(learn.heldRight == .magnifier && learn.badge == .question && learn.tilt == -5 && learn.eyes == .wide)
        let conduct = TempoPose.named(.conduct)
        #expect(conduct.gesture == .init(left: -6, right: 18) && conduct.heldRight == .baton && conduct.legs == .tiptoe)
        let walk = TempoPose.named(.walk)
        #expect(walk.gesture == .init(left: 18, right: -18, feet: true) && walk.legs == .stride && walk.period == 650)
        #expect(TempoPose.named(.worried).gesture == nil && TempoPose.named(.icon).level == 0.55)
    }

    // MARK: Compose

    @Test func everyStatePicksItsOwnPose() {
        for state in DayStory.State.allCases {
            let day = Self.day(for: state)
            #expect(DayStory(day).state == state, "\(state): the test day reads as that state")
            #expect(TempoSpec.compose(state: state, input: day, hour: 10).name == Self.statePose[state], "\(state)")
        }
    }

    @Test func timeOfDayChangesThePose() {
        let morning = Self.day(for: .morning)
        #expect(TempoSpec.compose(state: .morning, input: morning, hour: 10).name == .stretch)
        #expect(TempoSpec.compose(state: .morning, input: morning, hour: 11).name == .ponder)
        let quieter = Self.day(for: .fewerThanUsual)
        #expect(TempoSpec.compose(state: .fewerThanUsual, input: quieter, hour: 17).name == .mug)
        let evening = TempoSpec.compose(state: .fewerThanUsual, input: quieter, hour: 18)
        #expect(evening.name == .lantern)
        // The lantern still walks at the day's pace: 2 items under a usual 4 to 6 is 1,100 + 2 * 80 ms.
        #expect(evening.period == 1260 && evening.surface == .calm && evening.bubbles == 0)
    }

    @Test func aResolvedPlanIsTadaExceptOnDaysOffErrorsAndSealedDays() {
        for state in DayStory.State.allCases {
            var day = Self.day(for: state)
            (day.planned, day.resolved) = (4, 4)
            let name = TempoSpec.compose(state: state, input: day, hour: 15).name
            switch state {
            case .leave, .sick, .holiday, .weekend, .storeProblem:
                #expect(name == Self.statePose[state], "\(state) keeps its pose")
            case .sealed, .editedAfterWrapUp:
                #expect(name == Self.statePose[state], "\(state) keeps its pose")
            default:
                #expect(name == .tada, "\(state)")
            }
        }
        // Sealed is checked on the day, not only the state.
        var sealedToday = Self.day(for: .paused)
        (sealedToday.planned, sealedToday.resolved, sealedToday.sealedAt) = (4, 4, "18:00")
        #expect(TempoSpec.compose(state: .paused, input: sealedToday, hour: 18).name == .meditate)
        // One task still open is not tada.
        var open = Self.day(for: .inRhythm)
        (open.planned, open.resolved) = (4, 3)
        #expect(TempoSpec.compose(state: .inRhythm, input: open, hour: 15).name == .walk)
    }

    @Test func sickLeaveIsTheSickPose() {
        let spec = TempoSpec.compose(state: .sick, input: Self.day(for: .sick), hour: 10)
        #expect(spec.name == .sick)
        #expect(spec.pose.head == .thermometer && spec.pose.front == .scarf)
    }

    /// The prototype's `tempoFor` on the in-rhythm day at three times gives 630, 670 and 690 ms and levels .2, .4, .8.
    @Test func inRhythmBeatsSlowerThroughTheDay() {
        let cases: [(hour: Int, done: Int, items: Int, usual: ClosedRange<Int>, period: Int, level: Double)] = [
            (10, 1, 1, 1...1, 630, 0.2), (14, 2, 4, 4...6, 670, 0.4), (16, 4, 7, 6...8, 690, 0.8),
        ]
        for c in cases {
            let day = Self.input { d in (d.planned, d.resolved, d.items, d.usualByNow) = (5, c.done, c.items, c.usual) }
            let spec = TempoSpec.compose(state: .inRhythm, input: day, hour: c.hour)
            #expect(spec == TempoSheet.inRhythm(hour: c.hour, done: c.done, items: c.items, usual: c.usual))
            #expect(spec.name == .walk && spec.period == c.period && spec.surface == .wave && spec.bubbles == 0)
            #expect(abs(spec.level - c.level) < 1e-9)
        }
    }

    @Test func paceFollowsTheCountAgainstUsual() {
        func spec(_ state: DayStory.State, items: Int, usual: ClosedRange<Int>? = 6...8) -> TempoSpec {
            let day = Self.input { d in (d.planned, d.resolved, d.items, d.usualByNow) = (5, 2, items, usual) }
            return TempoSpec.compose(state: state, input: day, hour: 15)
        }
        // Above usual: brisk, choppy, a bubble per item over, capped at 3, never quicker than 340 ms.
        let two = spec(.moreThanUsual, items: 10)
        #expect(two.name == .brisk && two.period == 420 && two.surface == .choppy && two.bubbles == 2)
        let five = spec(.moreThanUsual, items: 13)
        #expect(five.period == 340 && five.bubbles == 3)
        #expect(spec(.moreThanUsual, items: 30).period == 340)
        #expect(spec(.moreThanUsual, items: 30).bubbles == TempoTokens.bubbleCap)
        // Walk turns brisk above usual, and brisk turns walk when it is not.
        #expect(spec(.inRhythm, items: 9).name == .brisk)
        let settled = spec(.moreThanUsual, items: 8)
        #expect(settled.name == .walk && settled.surface == .wave && settled.bubbles == 0 && settled.period == 680)
        // Brisk from walk keeps walk's own level when there is no plan.
        let noPlan = TempoSpec.compose(state: .inRhythm, input: Self.input { d in (d.items, d.usualByNow) = (12, 6...8) }, hour: 15)
        #expect(noPlan.name == .brisk && noPlan.level == TempoPose.named(.walk).level)
        // Below usual: slow and calm, never slower than 1,600 ms.
        let under = spec(.fewerThanUsual, items: 3, usual: 4...6)
        #expect(under.name == .mug && under.period == 1180 && under.surface == .calm && under.bubbles == 0)
        #expect(spec(.fewerThanUsual, items: 0, usual: 9...12).period == 1600)
        // No range reads as in rhythm.
        let noRange = spec(.inRhythm, items: 40, usual: nil)
        #expect(noRange.name == .walk && noRange.surface == .wave && noRange.period == 680)
        // An explicit pace wins over the input's.
        let paced = TempoSpec.compose(
            state: .inRhythm, input: Self.day(for: .inRhythm), hour: 15, pace: .init(items: 11, usualByNow: 6...8))
        #expect(paced.name == .brisk && paced.bubbles == 3)
        // Poses that do not walk keep their own beat whatever the count.
        let bell = TempoSpec.compose(state: .wrapUpDue, input: Self.day(for: .wrapUpDue), hour: 17)
        #expect(bell.period == 300 && bell.surface == .wave && bell.bubbles == 0)
    }

    @Test func theWaterIsThePlan() {
        func level(_ state: DayStory.State, _ change: (inout DayStory.Input) -> Void) -> Double {
            var day = Self.day(for: state)
            change(&day)
            return TempoSpec.compose(state: state, input: day, hour: 15).level
        }
        #expect(level(.inRhythm) { d in (d.planned, d.resolved) = (5, 2) } == 0.4)
        // Full when sealed, whatever the plan.
        #expect(level(.sealed) { d in (d.planned, d.resolved) = (5, 3) } == 1)
        #expect(level(.sealed) { d in d.planned = 0 } == 1)
        // History imported while syncing.
        #expect(level(.firstSync) { _ in } == 0.6)
        #expect(level(.firstSync) { d in d.importing = .init(label: "October", done: 0, total: 0) } == 0)
        // The pose's own level without a plan.
        #expect(level(.onCall) { _ in } == TempoPose.named(.headset).level)
        #expect(level(.leave) { _ in } == 0)
        // A plan wins over an import.
        #expect(level(.firstSync) { d in (d.planned, d.resolved) = (4, 1) } == 0.25)
    }

    @Test func aPoseByNameCarriesItsOwnLevelBeatAndSurface() {
        let chart = TempoSpec(pose: .chart)
        #expect(chart.level == 0.25 && chart.period == 800 && chart.surface == .wave && chart.bubbles == 0)
        #expect(TempoSpec(pose: .tick, level: 0.78).level == 0.78)
        #expect(TempoSpec(pose: .tick, level: 3).level == 1)
        let brisk = TempoSpec(pose: .brisk)
        #expect(brisk.surface == .choppy && brisk.bubbles == 2 && brisk.period == 420)
    }

    // MARK: Two moments never render the same Tempo

    /// Everything that changes the drawing; names and notes do not.
    static func look(_ spec: TempoSpec) -> String {
        let p = spec.pose
        let motion = p.gesture.map { "\($0) \(spec.period) \(spec.bubbles)" } ?? "held"
        return [
            "\(p.left) \(p.right)", "\(String(describing: p.heldLeft)) \(String(describing: p.heldRight))",
            "\(String(describing: p.head)) \(String(describing: p.front))", p.legs.rawValue, p.eyes.rawValue,
            p.mouth.rawValue, "\(String(describing: p.badge))", "\(p.tilt)", motion, "\(spec.level)", spec.surface.rawValue,
        ].joined(separator: "|")
    }

    @Test func noTwoMomentsRenderTheSameTempo() {
        var moments: [(String, TempoSpec)] = DayStory.State.allCases.map { state in
            ("state \(state)", TempoSpec.compose(state: state, input: Self.day(for: state), hour: 10))
        }
        moments.append(("late morning", TempoSpec.compose(state: .morning, input: Self.day(for: .morning), hour: 11)))
        moments.append(("quiet evening", TempoSpec.compose(state: .fewerThanUsual, input: Self.day(for: .fewerThanUsual), hour: 19)))
        for pose in TempoPose.all where pose.moment != .dayState {
            moments.append(("\(pose.moment) \(pose.name)", TempoSpec(pose: pose.name)))
        }
        #expect(moments.count == 49)
        var seen: [String: String] = [:]
        for (label, spec) in moments {
            let key = Self.look(spec)
            #expect(seen[key] == nil, "\(label) draws the same Tempo as \(seen[key] ?? "")")
            seen[key] = label
        }
        // Every pose is distinct by itself too.
        #expect(Set(TempoPose.all.map { Self.look(TempoSpec(pose: $0.name)) }).count == TempoPose.all.count)
    }

    // MARK: Motion

    @Test func theGesturePlaysEightBeatsThenHolds() {
        let walk = TempoSpec(pose: .walk)
        #expect(CadenceMotion.tempoBeats == 8)
        #expect(abs(walk.gestureDuration - 0.65 * 16) < 1e-9)
        let motion = TempoMotion(beat: 0.65, elapsed: 0.65 / 2)
        #expect(abs(motion.swing(18) - 18) < 1e-6, "a quarter cycle is the top of the swing")
        #expect(TempoMotion(beat: 0.65, elapsed: walk.gestureDuration).swing(18) == 0)
        #expect(TempoMotion(beat: 0.65, elapsed: walk.gestureDuration + 5).step(foot: 0) == 0)
        let held = TempoMotion(beat: 0.65, elapsed: nil)
        #expect(held.swing(18) == 0 && held.rock() == 0 && held.hop() == 0 && held.step(foot: 1) == 0)
        #expect(held.breathe() == CGSize(width: 1, height: 1))
        // A pose with no gesture never plays, so it never starts a timeline.
        #expect(TempoSpec(pose: .worried).playDuration == 0 && TempoSpec(pose: .icon).playDuration == 0)
        // Bubbles rise six times on a lively day, then stop.
        let lively = TempoSpec.compose(state: .moreThanUsual, input: Self.day(for: .moreThanUsual), hour: 15)
        #expect(lively.bubbles == 3 && lively.playDuration == 0.9 + 1.6 * 6)
        #expect(TempoMotion.bubble(elapsed: 1.6 * 6) == nil && TempoMotion.bubble(elapsed: -0.1) == nil)
        // An empty glass has nothing to bubble through.
        var empty = lively
        empty.level = 0.1
        #expect(empty.playDuration == empty.gestureDuration)
    }

    @Test func pathDataReadsTheWaySVGWritesIt() {
        // "5.6.6" is two numbers, "-.6" is one, and arc flags may be packed against the next number.
        let heart = TempoPath.parse("M0 5c-6-3.6-7.4-7-5.6-9.2c1.6-2 4.2-1.4 5.6.6c1.4-2 4-2.6 5.6-.6c1.8 2.2.4 5.6-5.6 9.2z")
        var ends: [CGPoint] = []
        heart.forEach { element in
            switch element {
            case .move(let p), .line(let p): ends.append(p)
            case .curve(let p, _, _), .quadCurve(let p, _): ends.append(p)
            case .closeSubpath: break
            }
        }
        let expected = [CGPoint(x: 0, y: 5), CGPoint(x: -5.6, y: -4.2), CGPoint(x: 0, y: -3.6), CGPoint(x: 5.6, y: -4.2), CGPoint(x: 0, y: 5)]
        #expect(ends.count == expected.count)
        for (a, b) in zip(ends, expected) { #expect(abs(a.x - b.x) < 1e-4 && abs(a.y - b.y) < 1e-4, "\(a) is \(b)") }
        let arc = TempoPath.parse("M0 0a3 3 0 010 6").boundingRect
        #expect(abs(arc.maxX - 3) < 0.01 && abs(arc.minX) < 0.01 && abs(arc.height - 6) < 0.01)
        let large = TempoPath.parse("M0 0a5 5 0 116 6").boundingRect
        #expect(large.width > 8, "the large arc goes the long way round")
    }

    // MARK: Drawing

    @MainActor @Test func everyPoseRendersAtPanelAndHeroSize() throws {
        for pose in TempoPose.all {
            for size in [CadenceTempoTokens.Size.panel, CadenceTempoTokens.Size.hero] {
                let renderer = ImageRenderer(content: TempoView(TempoSpec(pose: pose.name), size: size))
                renderer.scale = 2
                let image = try #require(renderer.cgImage, "\(pose.name) at \(size)")
                #expect(image.width == Int(size * 2), "\(pose.name) at \(size)")
                #expect(Self.inkedPixels(image) > image.width * image.height / 20, "\(pose.name) at \(size) draws something")
            }
        }
        let icon = try #require(ImageRenderer(content: TempoAppIcon(size: 64)).cgImage)
        #expect(icon.width == 64 && Self.inkedPixels(icon) > 64 * 64 / 2)
    }

    static func inkedPixels(_ image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                count += 1
            }
        }
        return count
    }
}

private typealias TempoTokens = CadenceTempoTokens.Pace
