import AppKit
import CadenceCore
import Testing

@testable import CadenceUI

@Suite struct MarkTests {
    /// The form with every colour taken away: what is left is what a colour-blind eye, or a monochrome bar, reads.
    static func colourless(_ form: MarkForm) -> MarkForm {
        var f = form
        f.water?.hue = .coral
        f.ring?.paint = .ink
        f.accent?.hue = .coral
        f.solid?.hue = .coral
        switch f.centre {
        case .dot?: f.centre = .dot(.ink)
        case .hollow?: f.centre = .hollow(.ink)
        case nil: break
        }
        return f
    }

    @Test func everyStateIsDistinctByFormAlone() {
        #expect(Set(MarkSpecimen.all.compactMap(\.state)) == Set(DayStory.State.allCases))
        // Every state at every level it can show: nothing resolved, part done, and all resolved where a state can
        // outrank plan settled. Plan settled is only ever all resolved; states below it are never all resolved.
        let neverAllResolved: Set<DayStory.State> = [.morning, .planned, .inRhythm, .moreThanUsual, .fewerThanUsual]
        var forms: [(name: String, form: MarkForm)] = [("discreet", .discreet)]
        for state in DayStory.State.allCases {
            if state != .planSettled {
                for level in [0, MarkSpecimen.partLevel] {
                    forms.append(("\(state) at \(level)", MarkForm(state: state, level: level, allResolved: false, discreet: false)))
                }
            }
            if !neverAllResolved.contains(state) {
                forms.append(("\(state) at 1", MarkForm(state: state, level: 1, allResolved: true, discreet: false)))
            }
        }
        for (i, a) in forms.enumerated() {
            for b in forms[(i + 1)...] where a.name.split(separator: " ")[0] != b.name.split(separator: " ")[0] {
                #expect(Self.colourless(a.form) != Self.colourless(b.form), "\(a.name) and \(b.name) differ only by colour")
            }
        }
    }

    @Test func levelIsResolvedOverPlannedFullWhenSealedHistoryWhileSyncingEmptyOnDaysOff() {
        #expect(MarkForm.level(.inRhythm, planned: 5, resolved: 2, importing: nil) == 0.4)
        #expect(MarkForm.level(.inRhythm, planned: 0, resolved: 0, importing: nil) == 0)
        #expect(MarkForm.level(.wrapUpDue, planned: 2, resolved: 5, importing: nil) == 1)
        #expect(MarkForm.level(.sealed, planned: 4, resolved: 1, importing: nil) == 1)
        #expect(MarkForm.level(.editedAfterWrapUp, planned: 0, resolved: 0, importing: nil) == 1)
        let october = DayStory.Import(label: "October", done: 12, total: 20)
        #expect(MarkForm.level(.firstSync, planned: 5, resolved: 5, importing: october) == 0.6)
        #expect(MarkForm.level(.firstSync, planned: 5, resolved: 5, importing: nil) == 0)
        for off in [DayStory.State.leave, .sick, .holiday, .weekend] {
            #expect(MarkForm.level(off, planned: 4, resolved: 2, importing: nil) == 0)
        }
    }

    @Test func waterShowsTheLevelAndNothingWhenEmpty() {
        let form = MarkForm(state: .inRhythm, level: 0.4, allResolved: false, discreet: false)
        #expect(form.water == MarkForm.Water(hue: .coral, level: 0.4))
        // Nothing resolved: a meniscus, never no water.
        #expect(MarkForm(state: .inRhythm, level: 0, allResolved: false, discreet: false).water == MarkForm.Water(hue: .coral, level: 0))
        #expect(MarkForm(state: .fewerThanUsual, level: 0.5, allResolved: false, discreet: false).water?.softness == CadenceMarkTokens.softQuieter)
        #expect(MarkForm(state: .paused, level: 0.5, allResolved: false, discreet: false).water?.softness == CadenceMarkTokens.softPaused)
        // Days off are empty whatever level is passed.
        #expect(MarkForm(state: .leave, level: 1, allResolved: true, discreet: false).water == nil)
    }

    @Test func everyResolvedTaskTurnsTheWaterBlueGreenExceptPausedOrSealed() {
        for state in [DayStory.State.inRhythm, .moreThanUsual, .fewerThanUsual, .wrapUpDue, .onCall, .sourceBehind, .learning, .firstSync] {
            let form = MarkForm(state: state, level: 1, allResolved: true, discreet: false)
            #expect(form.water?.hue == .green, "\(state)")
        }
        #expect(MarkForm(state: .paused, level: 1, allResolved: true, discreet: false).water?.hue == .coral)
        #expect(MarkForm(state: .sealed, level: 1, allResolved: true, discreet: false) == MarkForm(ring: nil, solid: .init(hue: .green)))
        #expect(MarkForm(state: .inRhythm, level: 0.5, allResolved: false, discreet: false).water?.hue == .coral)
        // A state with no water gains none.
        #expect(MarkForm(state: .planned, level: 1, allResolved: true, discreet: false).water == nil)
    }

    @Test func discreetIsTheRingOnly() {
        for state in DayStory.State.allCases {
            let form = MarkForm(state: state, level: 0.5, allResolved: false, discreet: true)
            #expect(form == MarkForm.discreet)
        }
        #expect(MarkForm.discreet == MarkForm(ring: .init(kind: .plain)))
    }

    @Test func attentionBreathesOnlyWhereTheSpecSays() {
        let breathing = DayStory.State.allCases.filter { MarkForm(state: $0, level: 0.5, allResolved: false, discreet: false).attention }
        #expect(Set(breathing) == [.morning, .wrapUpDue, .yesterdayOpen, .nothingLogged])
    }

    @Test func spotChecksAgainstTheTable() {
        func form(_ s: DayStory.State) -> MarkForm { MarkForm(state: s, level: 0.5, allResolved: false, discreet: false) }
        #expect(form(.storeProblem) == MarkForm(ring: nil, solid: .init(hue: .red, cut: .bang)))
        #expect(form(.editedAfterWrapUp).solid == .init(hue: .green, cut: .hollow))
        #expect(form(.planned).ring == .init(kind: .thick, paint: .hue(.blue)))
        #expect(form(.sick) == MarkForm(ring: .init(kind: .dashed), centre: .hollow(.ink)))
        #expect(form(.holiday).centre == .dot(.hue(.rose)))
        #expect(form(.weekend).ring == .init(kind: .dashed, faint: true))
        #expect(form(.closedUnsealed).accent == .init(kind: .halfDashed, hue: .amber))
        #expect(form(.onCall).accent == .init(kind: .ears, hue: .teal))
        #expect(form(.sourceBehind).ring == .init(kind: .broken, paint: .hue(.amber)))
        #expect(form(.nothingLogged).centre == .hollow(.hue(.amber)))
    }

    @Test @MainActor func rendersAnEighteenPointColourImageForEveryStateOnEveryBar() throws {
        for palette in BarHue.Bar.allCases {
            let dark = palette == .dark || palette == .darkMore
            let bar = MarkBar(
                appearance: NSAppearance(named: dark ? .darkAqua : .aqua)!,
                increaseContrast: palette == .lightMore || palette == .darkMore)
            #expect(bar.palette == palette)
            for specimen in MarkSpecimen.all + MarkSpecimen.empty {
                for motion in [MarkMotion.still, MarkMotion(riseFrom: 0.2, rise: 0.3, seal: 0.5, breath: 0.5, hover: true)] {
                    let image = MarkRenderer.image(specimen.form, bar: bar, motion: motion)
                    #expect(image.size == NSSize(width: 18, height: 18))
                    #expect(!image.isTemplate)
                    let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    #expect(cg.width > 0 && cg.height > 0, "\(specimen.name) on \(palette)")
                }
            }
        }
    }

    @Test @MainActor func crossfadeIsEighteenPoints() {
        let bar = MarkBar(appearance: NSAppearance(named: .aqua)!, increaseContrast: false)
        let old = MarkRenderer.image(.discreet, bar: bar)
        let new = MarkRenderer.image(MarkSpecimen.all[0].form, bar: bar)
        #expect(MarkRenderer.crossfade(from: old, to: new, fraction: 0.5).size == NSSize(width: 18, height: 18))
    }

    @Test func breathFallsToTheFloorAndReturns() {
        #expect(MarkRenderer.breathAlpha(nil) == 1)
        #expect(abs(MarkRenderer.breathAlpha(0) - 1) < 1e-9)
        #expect(abs(MarkRenderer.breathAlpha(0.5) - CadenceMarkTokens.breathFloor) < 1e-9)
    }
}
