// The menu-bar mark as a pure description (docs/SPEC.md section 4.1): one circle read through five channels, the
// water, the ring, arcs on the ring, a centre and a solid disc. Every day state has its own form, and colour adds
// meaning on top, never alone. Built without AppKit, so every state can be tested.
import CadenceCore
import Foundation

/// An accent of the menu-bar palette (`CadenceBarColor`).
public enum MarkHue: String, Sendable, CaseIterable {
    case coral, sage, blue, green, amber, teal, lilac, rose, red

    public var token: BarHue {
        switch self {
        case .coral: CadenceBarColor.coral
        case .sage: CadenceBarColor.sage
        case .blue: CadenceBarColor.blue
        case .green: CadenceBarColor.green
        case .amber: CadenceBarColor.amber
        case .teal: CadenceBarColor.teal
        case .lilac: CadenceBarColor.lilac
        case .rose: CadenceBarColor.rose
        case .red: CadenceBarColor.red
        }
    }
}

/// Ink is the bar's own text colour, so neutral parts follow the system's light, dark and tinted bars.
public enum MarkPaint: Sendable, Equatable {
    case ink
    case hue(MarkHue)
}

public struct MarkForm: Sendable, Equatable {
    /// Resolved planned tasks over planned, inside a clear gap within the ring.
    public struct Water: Sendable, Equatable {
        public var hue: MarkHue
        /// 0...1. At 0 the water is a meniscus, so a water state never collapses into a ring-only form.
        public var level: Double
        /// Opacity: 1, or softer on a quieter day and while paused.
        public var softness: Double

        public init(hue: MarkHue, level: Double, softness: Double = 1) {
            self.hue = hue
            self.level = level
            self.softness = softness
        }
    }

    public struct Ring: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case plain, thick, dashed, dotted
            /// Open at the top: capture paused.
            case openTop
            /// Broken at the upper right: a source is behind.
            case broken
        }

        public var kind: Kind
        /// At 45%, on its own or with a dashed ring.
        public var faint: Bool
        /// Ink is the neutral ring, which lifts on hover and goes to full ink under Increase Contrast.
        public var paint: MarkPaint

        public init(kind: Kind, faint: Bool = false, paint: MarkPaint = .ink) {
            self.kind = kind
            self.faint = faint
            self.paint = paint
        }
    }

    public struct Accent: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// At the top: wrap-up.
            case notch
            /// Either side: on call.
            case ears
            /// The left half: yesterday still open.
            case half
            /// The left half, dashed: a day closed unsealed.
            case halfDashed
        }

        public var kind: Kind
        public var hue: MarkHue

        public init(kind: Kind, hue: MarkHue) {
            self.kind = kind
            self.hue = hue
        }
    }

    public enum Centre: Sendable, Equatable {
        /// Something needs you.
        case dot(MarkPaint)
        /// Nothing is logged.
        case hollow(MarkPaint)
    }

    /// The day is closed, or the store is broken.
    public struct Solid: Sendable, Equatable {
        public enum Cut: Sendable, Equatable {
            case none
            /// A late addition after the seal.
            case hollow
            /// The "!" of a problem.
            case bang
        }

        public var hue: MarkHue
        public var cut: Cut

        public init(hue: MarkHue, cut: Cut = .none) {
            self.hue = hue
            self.cut = cut
        }
    }

    public var water: Water?
    /// Nil only under a solid disc.
    public var ring: Ring?
    public var accent: Accent?
    public var centre: Centre?
    public var solid: Solid?
    /// The attention part (notch, half or centre) breathes when this state arrives.
    public var attention: Bool

    public init(
        water: Water? = nil, ring: Ring? = Ring(kind: .plain, faint: false, paint: .ink), accent: Accent? = nil,
        centre: Centre? = nil, solid: Solid? = nil, attention: Bool = false
    ) {
        self.water = water
        self.ring = ring
        self.accent = accent
        self.centre = centre
        self.solid = solid
        self.attention = attention
    }

    /// Discreet mode: the ring alone, with no water and no colour.
    public static let discreet = MarkForm()

    /// The form of a day state.
    ///
    /// - Parameters:
    ///   - level: the water, 0...1, usually from `level(_:planned:resolved:importing:)`. Days off are always empty
    ///     and sealed days always full.
    ///   - allResolved: every planned task is resolved. The water then turns blue-green whatever the state, except
    ///     while paused or sealed.
    ///   - discreet: the ring only.
    public init(state: DayStory.State, level: Double, allResolved: Bool, discreet: Bool) {
        guard !discreet else {
            self = .discreet
            return
        }
        let level = Self.rule(state, min(1, max(0, level)))
        func fill(_ hue: MarkHue, soft: Double = 1) -> Water? {
            Water(hue: hue, level: level, softness: soft)
        }
        func line(_ kind: Ring.Kind, faint: Bool = false, _ paint: MarkPaint = .ink) -> Ring {
            Ring(kind: kind, faint: faint, paint: paint)
        }
        let plain = line(.plain)

        switch state {
        case .firstRun:
            self.init(ring: line(.plain, faint: true), centre: .dot(.hue(.lilac)))
        case .firstSync:
            self.init(water: fill(.lilac), ring: line(.dotted, .hue(.lilac)))
        case .learning:
            self.init(water: fill(.lilac), ring: line(.plain, faint: true))
        case .morning:
            self.init(ring: plain, centre: .dot(.hue(.amber)), attention: true)
        case .planned:
            self.init(ring: line(.thick, .hue(.blue)))
        case .inRhythm:
            self.init(water: fill(.coral), ring: plain)
        case .moreThanUsual:
            self.init(water: fill(.coral), ring: line(.thick, .hue(.coral)))
        case .fewerThanUsual:
            self.init(water: fill(.sage, soft: CadenceMarkTokens.softQuieter), ring: plain)
        case .planSettled:
            self.init(water: fill(.green), ring: plain)
        case .wrapUpDue:
            self.init(water: fill(.coral), ring: plain, accent: Accent(kind: .notch, hue: .amber), attention: true)
        case .sealed:
            self.init(ring: nil, solid: Solid(hue: .green, cut: .none))
        case .editedAfterWrapUp:
            self.init(ring: nil, solid: Solid(hue: .green, cut: .hollow))
        case .yesterdayOpen:
            self.init(ring: plain, accent: Accent(kind: .half, hue: .amber), attention: true)
        case .closedUnsealed:
            self.init(ring: plain, accent: Accent(kind: .halfDashed, hue: .amber))
        case .onCall:
            self.init(water: fill(.teal), ring: line(.plain, .hue(.teal)), accent: Accent(kind: .ears, hue: .teal))
        case .leave:
            self.init(ring: line(.dashed))
        case .sick:
            self.init(ring: line(.dashed), centre: .hollow(.ink))
        case .holiday:
            self.init(ring: line(.dashed), centre: .dot(.hue(.rose)))
        case .weekend:
            self.init(ring: line(.dashed, faint: true))
        case .paused:
            self.init(water: fill(.coral, soft: CadenceMarkTokens.softPaused), ring: line(.openTop))
        case .sourceBehind:
            self.init(water: fill(.coral), ring: line(.broken, .hue(.amber)))
        case .nothingLogged:
            self.init(ring: plain, centre: .hollow(.hue(.amber)), attention: true)
        case .storeProblem:
            self.init(ring: nil, solid: Solid(hue: .red, cut: .bang))
        }

        if allResolved, state != .paused, !Self.isSealed(state), self.water != nil {
            self.water?.hue = .green
        }
    }

    /// The water for a state: resolved over planned, full when sealed, the history imported while the first sync
    /// runs, and empty on days off or with nothing planned.
    public static func level(_ state: DayStory.State, planned: Int, resolved: Int, importing: DayStory.Import?) -> Double {
        if state == .firstSync {
            guard let importing, importing.total > 0 else { return 0 }
            return rule(state, Double(importing.done) / Double(importing.total))
        }
        return rule(state, planned > 0 ? Double(resolved) / Double(planned) : 0)
    }

    /// The day is over.
    public static func isSealed(_ state: DayStory.State) -> Bool {
        state == .sealed || state == .editedAfterWrapUp
    }

    static func rule(_ state: DayStory.State, _ level: Double) -> Double {
        switch state {
        case .leave, .sick, .holiday, .weekend: 0
        case .sealed, .editedAfterWrapUp: 1
        default: min(1, max(0, level))
        }
    }
}
