// The sealing moment (docs/SPEC.md sections 4.5, 5.3 and 5.7): the sealed world sweeps up over the sheet from its
// bottom edge in 1,400 ms, Tempo tucks in under its blanket, and the words say the day is closed. Reduce Motion
// shows the end state only. The sound and the haptic are played by whoever seals, once, as the sweep starts.
import CadenceCore
import SwiftUI

/// Draws Tempo in a pose at a size. Tempo is built on its own (section 5.3); the app passes this in, and without it
/// the slot stays empty, as it does when Tempo is off or discreet mode is on.
public typealias SheetTempo = @MainActor (_ pose: String, _ size: CGFloat) -> AnyView

/// Where Tempo goes in a sheet. Empty when there is no renderer or Tempo is hidden.
public struct SheetTempoSlot: View {
    let pose: String
    let size: CGFloat
    let render: SheetTempo?
    let shows: Bool

    public init(pose: String, size: CGFloat, render: SheetTempo?, shows: Bool) {
        self.pose = pose
        self.size = size
        self.render = render
        self.shows = shows
    }

    public var body: some View {
        if shows, let render {
            render(pose, size)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

public struct SealingView: View {
    public static let headline = String(localized: "Sealed.")
    public static let line = String(localized: "Everything is accounted for. Rest well.")
    /// Tempo's pose for this moment (section 5.3, other moments).
    public static let tempoPose = "blanket"
    /// Tempo stands this tall over the words, as in the design.
    public static let tempoSize = CadenceSpace.s48 * 2 + CadenceSpace.s24
    /// The end state stays on screen this long after the sweep, so the words can be read.
    public static let hold = CadenceMotion.sweep.duration
    /// How long the moment lasts from the seal to the sheet closing.
    public static func duration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? hold : CadenceMotion.sweep.duration + hold
    }

    /// A ready-to-close sheet is about this tall, so the specimen sweeps over the same ground.
    static let specimenHeight = CadenceSpace.s48 * 8

    let tempo: SheetTempo?
    let showsTempo: Bool
    /// Starts at the end state. Specimens use it; Reduce Motion gets it on its own.
    let settled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swept = false

    public init(tempo: SheetTempo?, showsTempo: Bool, settled: Bool = false) {
        self.tempo = tempo
        self.showsTempo = showsTempo
        self.settled = settled
    }

    public var body: some View {
        let world = CadenceWorld.forest
        let shown = swept || settled || reduceMotion
        GeometryReader { geometry in
            let reach = hypot(geometry.size.width / 2, geometry.size.height) * 2
            ZStack {
                world.bg.color
                VStack(spacing: 0) {
                    SheetTempoSlot(pose: Self.tempoPose, size: Self.tempoSize, render: tempo, shows: showsTempo)
                        .padding(.bottom, CadenceSpace.s8)
                    Text(Self.headline)
                        .cadenceType(CadenceType.numeralLarge)
                    Text(Self.line)
                        .cadenceType(SheetType.sealLine)
                        .padding(.top, CadenceSpace.s6)
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(world.ink.color)
                .padding(SheetLayout.padding)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : CadenceSpace.s12)
            }
            .mask {
                Circle()
                    .frame(width: shown ? reach : 0, height: shown ? reach : 0)
                    .position(x: geometry.size.width / 2, y: geometry.size.height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.headline) \(Self.line)")
        .accessibilityAddTraits(.isStaticText)
        .onAppear {
            AccessibilityNotification.Announcement("\(Self.headline) \(Self.line)").post()
            guard !settled, !reduceMotion else { return }
            withAnimation(CadenceMotion.sweep.animation) { swept = true }
        }
    }
}
