// Every Tempo pose on one page, with its note, and one state through a day, rendered by `make token-sheet`.
import CadenceCore
import SwiftUI

public struct TempoSheet: View {
    public init() {}

    private enum Layout {
        static let width: CGFloat = 1180
        static let columns = 8
        static let pose = CadenceTempoTokens.Size.sheet
        static let stage: CGFloat = 128
        static let stageHeight: CGFloat = 200
    }

    /// In rhythm on one day at three times: the water is the plan, the beat slows through the afternoon.
    static let day: [(clock: String, hour: Int, done: Int, items: Int, usual: ClosedRange<Int>)] = [
        ("10:00", 10, 1, 1, 1...1), ("14:00", 14, 2, 4, 4...6), ("16:48", 16, 4, 7, 6...8),
    ]

    static func inRhythm(hour: Int, done: Int, items: Int, usual: ClosedRange<Int>) -> TempoSpec {
        var input = DayStory.Input(date: LocalDate(year: 2026, month: 10, day: 29)!)
        input.countedWorkdays = 20
        input.planned = 5
        input.resolved = done
        input.done = done
        input.items = items
        input.usualByNow = usual
        return TempoSpec.compose(state: .inRhythm, input: input, hour: hour)
    }

    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s24) {
            Text("Tempo, \(colorScheme == .dark ? "dark" : "light")")
                .cadenceType(CadenceType.section)
                .foregroundStyle(CadenceColor.ink.color)
            section("Day states", .dayState)
            section("First run", .firstRun)
            section("Recap frames", .recap)
            section("Other moments", .other)
            strip
        }
        .padding(CadenceSpace.s24)
        .frame(width: Layout.width)
        .background(CadenceColor.canvas.color)
    }

    /// The held pose, so the snapshot never catches a gesture halfway.
    private func held(_ spec: TempoSpec, _ size: CGFloat) -> some View {
        TempoCanvas(spec: spec, elapsed: nil)
            .frame(width: size, height: TempoView.height(forWidth: size))
            .accessibilityHidden(true)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .cadenceType(CadenceType.label)
            .foregroundStyle(CadenceColor.ink3.color)
    }

    private func section(_ title: String, _ moment: TempoPose.Moment) -> some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s8) {
            label(title)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: CadenceSpace.s8), count: Layout.columns),
                alignment: .leading, spacing: CadenceSpace.s8
            ) {
                ForEach(TempoPose.all.filter { $0.moment == moment }, id: \.name) { pose in
                    VStack(spacing: CadenceSpace.s4) {
                        held(TempoSpec(pose: pose.name), Layout.pose)
                        Text(pose.note)
                            .cadenceType(CadenceType.comparison)
                            .foregroundStyle(CadenceColor.ink2.color)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, CadenceSpace.s12)
                    .padding(.horizontal, CadenceSpace.s4)
                    .padding(.bottom, CadenceSpace.s8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CadenceColor.track.color, in: RoundedRectangle(cornerRadius: CadenceRadius.control, style: .continuous))
                }
            }
        }
    }

    private var strip: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s8) {
            label("The same state on one day: in rhythm")
            HStack(spacing: CadenceSpace.s12) {
                ForEach(Self.day, id: \.clock) { moment in
                    let spec = Self.inRhythm(hour: moment.hour, done: moment.done, items: moment.items, usual: moment.usual)
                    ZStack(alignment: .bottomLeading) {
                        held(spec, Layout.stage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text("\(moment.clock), \(moment.done) of 5 done, \(moment.items) item\(moment.items == 1 ? "" : "s"), \(spec.period) ms beat")
                            .cadenceType(CadenceType.comparison)
                            .fontWeight(.bold)
                            .foregroundStyle(CadenceWorld.coral.ink.color)
                            .padding(.leading, CadenceSpace.s16)
                            .padding(.bottom, CadenceSpace.s12)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Layout.stageHeight)
                    .background(CadenceWorld.coral.bg.color, in: RoundedRectangle(cornerRadius: CadenceRadius.tile, style: .continuous))
                }
            }
        }
    }
}
