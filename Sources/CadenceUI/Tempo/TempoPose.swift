// Tempo's poses (docs/SPEC.md section 5.3), as data. Each pose is the prototype's, field for field: the arms as a
// shoulder angle and an elbow bend, held props, a head prop and a front prop, legs, eyes, mouth, a badge, a tilt, one
// gesture with its period, a water level for days without a plan, a water surface and a note.
import CadenceCore

public struct TempoPose: Sendable, Equatable {
    public enum Name: String, Sendable, CaseIterable {
        // Day states
        case hello, sync, learn, stretch, ponder, clipboard, walk, brisk, mug, lantern, tada, bell, sleep, peek
        case lookback, headset, lounge, sick, party, read, meditate, lookout, shrug, scratch, worried
        // First run
        case welcome, lock, plug, laptop, carry, raise
        // Recaps
        case reviewer, tick, parcel, friend, chat, scroll, stack, calendar, metronome, stamp
        case twoMugs = "twomugs"
        case cards
        // Other moments
        case blanket, broom, chart, wrench, icon, conduct
    }

    /// Where a pose is used.
    public enum Moment: Sendable, CaseIterable {
        case dayState, firstRun, recap, other
    }

    /// An arm: the shoulder angle in degrees from straight down, outward positive, then the elbow's bend from there.
    /// A front arm is drawn over the glass.
    public struct Arm: Sendable, Equatable, Hashable {
        public var shoulder: Double
        public var elbow: Double
        public var front: Bool

        public init(_ shoulder: Double, _ elbow: Double, front: Bool = false) {
            self.shoulder = shoulder
            self.elbow = elbow
            self.front = front
        }
    }

    /// Everything Tempo can hold, wear or stand behind.
    public enum Prop: String, Sendable, CaseIterable {
        // In a hand
        case bell, clipboard, mug, mug2, magnifier, hourglass, page, note, drink, lantern, plug, paper, pencil, scroll
        case stamp, cards, wrench, chart, baton
        // On the glass
        case headset, thermometer, hat, glasses
        // In front of the glass
        case book, scarf, lock, laptop, box, parcel, stack, calendar, metronome, seal, blanket, broom
    }

    public enum Legs: String, Sendable { case stand, stride, tiptoe, hop, sit, cross, lie }
    public enum Eyes: String, Sendable { case open, wide, aside, down, happy, calm, closed, droopy, one, worried, shades }
    public enum Mouth: String, Sendable { case smile, grin, yawn, rest, o, worry }
    public enum Badge: String, Sendable { case sun, question, z, confetti, pause, heart, bubble, bang }
    /// The water's surface: a wave on the beat, choppy when brisk, calm when quiet, still at rest, dotted while filling.
    public enum Surface: String, Sendable { case wave, choppy, calm, still, dotted }
    public enum BodyMove: String, Sendable { case breathe, rock, hop }

    /// The one gesture: arm swings in degrees, feet that step, and a body move.
    public struct Gesture: Sendable, Equatable, Hashable {
        public var left: Double
        public var right: Double
        public var feet: Bool
        public var body: BodyMove?

        public init(left: Double = 0, right: Double = 0, feet: Bool = false, body: BodyMove? = nil) {
            self.left = left
            self.right = right
            self.feet = feet
            self.body = body
        }
    }

    public var name: Name
    public var moment: Moment
    public var left: Arm
    public var right: Arm
    public var heldLeft: Prop?
    public var heldRight: Prop?
    public var head: Prop?
    public var front: Prop?
    public var legs: Legs
    public var eyes: Eyes
    public var mouth: Mouth
    public var badge: Badge?
    /// Degrees, turned around the feet.
    public var tilt: Double
    public var gesture: Gesture?
    /// Milliseconds per beat. Nil when the pose has no period of its own.
    public var period: Int?
    /// The water when the day has no plan of its own, 0 to 1.
    public var level: Double
    public var surface: Surface?
    public var note: String

    init(
        _ name: Name, _ moment: Moment, l: Arm, r: Arm, hl: Prop? = nil, hr: Prop? = nil, head: Prop? = nil,
        front: Prop? = nil, legs: Legs, eyes: Eyes, mouth: Mouth, badge: Badge? = nil, tilt: Double = 0,
        go: Gesture? = nil, period: Int? = nil, level: Double, surface: Surface? = nil, note: String
    ) {
        self.name = name
        self.moment = moment
        self.left = l
        self.right = r
        self.heldLeft = hl
        self.heldRight = hr
        self.head = head
        self.front = front
        self.legs = legs
        self.eyes = eyes
        self.mouth = mouth
        self.badge = badge
        self.tilt = tilt
        self.gesture = go
        self.period = period
        self.level = level
        self.surface = surface
        self.note = note
    }

    /// The pose with this name.
    public static func named(_ name: Name) -> TempoPose { byName[name]! }

    private static let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    /// Every pose, in the prototype's order.
    public static let all: [TempoPose] = [
        // Day states
        .init(.hello, .dayState, l: .init(62, -112), r: .init(150, 18), legs: .stand, eyes: .happy, mouth: .grin, go: .init(right: 16), period: 520, level: 0, note: "First run: waves hello"),
        .init(.sync, .dayState, l: .init(-36, -58, front: true), r: .init(-36, -58, front: true), front: .hourglass, legs: .sit, eyes: .open, mouth: .o, go: .init(body: .breathe), period: 1100, level: 0.3, surface: .dotted, note: "First sync: waits with an hourglass"),
        .init(.learn, .dayState, l: .init(24, 8), r: .init(-96, -26, front: true), hr: .magnifier, legs: .stand, eyes: .wide, mouth: .o, badge: .question, tilt: -5, go: .init(body: .rock), period: 1200, level: 0.3, note: "Still learning: peers closer"),
        .init(.stretch, .dayState, l: .init(166, 6), r: .init(166, 6), legs: .tiptoe, eyes: .closed, mouth: .yawn, badge: .sun, go: .init(left: 6, right: 6, body: .breathe), period: 1000, level: 0, note: "Morning: stretches and yawns"),
        .init(.ponder, .dayState, l: .init(24, 8), r: .init(-60, -88, front: true), legs: .stand, eyes: .aside, mouth: .smile, badge: .sun, tilt: 4, go: .init(body: .rock), period: 1300, level: 0, note: "Late morning: wonders what is first"),
        .init(.clipboard, .dayState, l: .init(-30, -62, front: true), r: .init(-64, -10, front: true), hl: .clipboard, legs: .stand, eyes: .open, mouth: .smile, tilt: 3, go: .init(right: 6), period: 700, level: 0, surface: .calm, note: "Planned: points at the list"),
        .init(.walk, .dayState, l: .init(22, 10), r: .init(22, 10), legs: .stride, eyes: .open, mouth: .smile, go: .init(left: 18, right: -18, feet: true), period: 650, level: 0.55, note: "In rhythm: walks on the beat"),
        .init(.brisk, .dayState, l: .init(46, 62), r: .init(46, 62), legs: .stride, eyes: .happy, mouth: .smile, go: .init(left: 24, right: -24, feet: true), period: 420, level: 0.7, surface: .choppy, note: "More than usual: a brisk walk"),
        .init(.mug, .dayState, l: .init(22, 8), r: .init(20, -120, front: true), hr: .mug, legs: .stride, eyes: .calm, mouth: .smile, go: .init(left: 10, feet: true), period: 1300, level: 0.4, surface: .calm, note: "Fewer than usual: strolls with a mug"),
        .init(.lantern, .dayState, l: .init(70, -30), r: .init(22, 8), hl: .lantern, legs: .stride, eyes: .calm, mouth: .smile, go: .init(left: 6, feet: true), period: 1400, level: 0.4, surface: .calm, note: "Quiet evening: a lantern"),
        .init(.tada, .dayState, l: .init(138, -12), r: .init(138, -12), legs: .hop, eyes: .happy, mouth: .grin, go: .init(body: .hop), period: 560, level: 1, note: "Plan settled: ta-da"),
        .init(.bell, .dayState, l: .init(24, 8), r: .init(124, 34), hr: .bell, legs: .stand, eyes: .open, mouth: .o, go: .init(right: 14), period: 300, level: 0.6, note: "Wrap-up due: rings a bell"),
        .init(.sleep, .dayState, l: .init(6, 0), r: .init(6, 0), legs: .lie, eyes: .closed, mouth: .rest, badge: .z, go: .init(body: .breathe), period: 1600, level: 1, surface: .still, note: "Sealed: lies down and sleeps"),
        .init(.peek, .dayState, l: .init(6, 0), r: .init(150, 8), hr: .note, legs: .lie, eyes: .one, mouth: .smile, go: .init(right: 8), period: 900, level: 1, surface: .still, note: "Late addition: one eye, one note"),
        .init(.lookback, .dayState, l: .init(58, 30), r: .init(22, 8), hl: .page, legs: .stand, eyes: .aside, mouth: .o, tilt: -9, go: .init(left: 6), period: 1100, level: 0, note: "Yesterday open: looks back at it"),
        .init(.headset, .dayState, l: .init(30, 10), r: .init(146, -96), head: .headset, legs: .tiptoe, eyes: .open, mouth: .o, go: .init(left: 10, body: .rock), period: 600, level: 0.5, note: "On call: hand to the earpiece"),
        .init(.lounge, .dayState, l: .init(150, -128), r: .init(10, -120, front: true), hr: .drink, legs: .sit, eyes: .shades, mouth: .grin, tilt: -6, go: .init(body: .rock), period: 1500, level: 0, note: "On leave: feet up"),
        .init(.sick, .dayState, l: .init(-34, -50, front: true), r: .init(-34, -50, front: true), head: .thermometer, front: .scarf, legs: .sit, eyes: .droopy, mouth: .rest, go: .init(body: .breathe), period: 1700, level: 0, note: "Off sick: wrapped up warm"),
        .init(.party, .dayState, l: .init(156, 0), r: .init(156, 0), head: .hat, legs: .hop, eyes: .happy, mouth: .grin, badge: .confetti, go: .init(body: .hop), period: 480, level: 0, note: "Holiday: party hat"),
        .init(.read, .dayState, l: .init(-40, -46, front: true), r: .init(-40, -46, front: true), front: .book, legs: .sit, eyes: .down, mouth: .smile, go: .init(body: .breathe), period: 1500, level: 0, note: "Weekend: reads a book"),
        .init(.meditate, .dayState, l: .init(58, -70), r: .init(58, -70), legs: .cross, eyes: .closed, mouth: .rest, badge: .pause, go: .init(body: .breathe), period: 1800, level: 0.5, surface: .still, note: "Paused: sits still and breathes"),
        .init(.lookout, .dayState, l: .init(24, 8), r: .init(168, 62, front: true), legs: .tiptoe, eyes: .aside, mouth: .o, tilt: 6, go: .init(body: .rock), period: 1000, level: 0.5, note: "Source behind: looks into the distance"),
        .init(.shrug, .dayState, l: .init(104, -96), r: .init(104, -96), legs: .stand, eyes: .down, mouth: .rest, go: .init(left: 6, right: 6), period: 1200, level: 0, note: "Nothing logged: a gentle shrug"),
        .init(.scratch, .dayState, l: .init(24, 8), r: .init(175, 40), legs: .stand, eyes: .calm, mouth: .o, tilt: 7, go: .init(right: 6), period: 500, level: 0, note: "Closed unsealed: scratches its head"),
        .init(.worried, .dayState, l: .init(-120, 40, front: true), r: .init(-120, 40, front: true), legs: .tiptoe, eyes: .worried, mouth: .worry, badge: .bang, level: 0, surface: .still, note: "A problem: honest about it"),
        // First run
        .init(.welcome, .firstRun, l: .init(112, 6), r: .init(112, 6), legs: .stand, eyes: .happy, mouth: .grin, go: .init(left: 8, right: 8), period: 800, level: 0.2, note: "Welcome: arms open"),
        .init(.lock, .firstRun, l: .init(-40, -50, front: true), r: .init(-40, -50, front: true), front: .lock, legs: .stand, eyes: .open, mouth: .smile, level: 0.2, note: "Your data: keeps it locked here"),
        .init(.plug, .firstRun, l: .init(24, 8), r: .init(96, 20), hr: .plug, legs: .stride, eyes: .open, mouth: .smile, go: .init(right: 6), period: 900, level: 0.2, note: "GitHub: plugs in"),
        .init(.laptop, .firstRun, l: .init(-44, -42, front: true), r: .init(-44, -42, front: true), front: .laptop, legs: .sit, eyes: .down, mouth: .smile, level: 0.2, note: "Claude Code: at the keyboard"),
        .init(.carry, .firstRun, l: .init(-26, -66, front: true), r: .init(-26, -66, front: true), front: .box, legs: .stride, eyes: .open, mouth: .o, go: .init(feet: true), period: 900, level: 0.2, note: "History: carries October in"),
        .init(.raise, .firstRun, l: .init(-50, -60, front: true), r: .init(172, 0), legs: .stand, eyes: .open, mouth: .smile, level: 0.2, note: "Permissions: asks politely"),
        // Recaps
        .init(.reviewer, .recap, l: .init(-56, -40, front: true), r: .init(24, 8), hl: .paper, head: .glasses, legs: .stand, eyes: .open, mouth: .smile, level: 0.5, note: "Reviews: reads closely"),
        .init(.tick, .recap, l: .init(-30, -62, front: true), r: .init(-70, -24, front: true), hl: .clipboard, hr: .pencil, legs: .stand, eyes: .down, mouth: .smile, level: 0.78, note: "Plan: ticks the list"),
        .init(.parcel, .recap, l: .init(-34, -56, front: true), r: .init(-34, -56, front: true), front: .parcel, legs: .stride, eyes: .happy, mouth: .smile, level: 0.6, note: "Delivered: carries the parcel"),
        .init(.friend, .recap, l: .init(150, 14), r: .init(150, 14), legs: .stand, eyes: .happy, mouth: .grin, badge: .heart, go: .init(left: 14, right: -14), period: 600, level: 0.6, note: "People: waves to a friend"),
        .init(.chat, .recap, l: .init(24, 8), r: .init(76, -60), legs: .stand, eyes: .open, mouth: .o, badge: .bubble, go: .init(right: 8), period: 700, level: 0.6, note: "With AI: talks it through"),
        .init(.scroll, .recap, l: .init(-30, -64, front: true), r: .init(24, 8), hl: .scroll, legs: .stand, eyes: .wide, mouth: .o, level: 0.84, note: "Month of plans: a long list"),
        .init(.stack, .recap, l: .init(-20, -74, front: true), r: .init(-20, -74, front: true), front: .stack, legs: .tiptoe, eyes: .open, mouth: .o, level: 0.7, note: "Merged: a stack of parcels"),
        .init(.calendar, .recap, l: .init(24, 8), r: .init(96, 4), front: .calendar, legs: .stand, eyes: .happy, mouth: .smile, level: 0.9, note: "Consistency: points at the calendar"),
        .init(.metronome, .recap, l: .init(24, 8), r: .init(24, 8), front: .metronome, legs: .stand, eyes: .calm, mouth: .smile, go: .init(body: .rock), period: 700, level: 0.84, note: "Steady: keeps time"),
        .init(.stamp, .recap, l: .init(24, 8), r: .init(-20, -40, front: true), hr: .stamp, front: .seal, legs: .stand, eyes: .open, mouth: .smile, level: 0.7, note: "Proof: stamps it"),
        .init(.twoMugs, .recap, l: .init(20, -120, front: true), r: .init(20, -120, front: true), hl: .mug, hr: .mug2, legs: .stand, eyes: .happy, mouth: .smile, level: 0.5, note: "Since your 1:1: two cups"),
        .init(.cards, .recap, l: .init(24, 8), r: .init(-60, -50, front: true), hr: .cards, legs: .stand, eyes: .open, mouth: .smile, tilt: -4, level: 0.5, note: "Reprioritised: reorders the cards"),
        // Other moments
        .init(.blanket, .other, l: .init(-44, -60, front: true), r: .init(-44, -60, front: true), front: .blanket, legs: .sit, eyes: .closed, mouth: .smile, go: .init(body: .breathe), period: 1600, level: 1, surface: .still, note: "Sealing: tucks in"),
        .init(.broom, .other, l: .init(-46, -26, front: true), r: .init(-22, -30, front: true), front: .broom, legs: .stride, eyes: .happy, mouth: .smile, go: .init(left: 8, right: 8), period: 600, level: 0.3, note: "Inbox empty: sweeps up"),
        .init(.chart, .other, l: .init(-30, -62, front: true), r: .init(24, 8), hl: .chart, legs: .stand, eyes: .wide, mouth: .smile, level: 0.25, note: "Too little data: plots the first dots"),
        .init(.wrench, .other, l: .init(24, 8), r: .init(96, -40), hr: .wrench, legs: .stand, eyes: .open, mouth: .smile, go: .init(right: 10), period: 500, level: 0.5, note: "Settings: tinkers"),
        .init(.icon, .other, l: .init(24, 8), r: .init(24, 8), legs: .stand, eyes: .open, mouth: .smile, level: 0.55, note: "App icon: Tempo at rest"),
        .init(.conduct, .other, l: .init(60, -30), r: .init(130, 26), hr: .baton, legs: .tiptoe, eyes: .happy, mouth: .smile, go: .init(left: -6, right: 18), period: 650, level: 0.55, note: "Cadence: keeps the beat"),
    ]

    /// The first-run steps, in order.
    public static let onboarding: [Name] = [.welcome, .lock, .plug, .laptop, .carry, .raise]

    /// The pose a day state picks before the day adapts it.
    public static func name(for state: DayStory.State) -> Name {
        switch state {
        case .firstRun: .hello
        case .firstSync: .sync
        case .learning: .learn
        case .morning: .stretch
        case .planned: .clipboard
        case .inRhythm: .walk
        case .moreThanUsual: .brisk
        case .fewerThanUsual: .mug
        case .planSettled: .tada
        case .wrapUpDue: .bell
        case .sealed: .sleep
        case .editedAfterWrapUp: .peek
        case .yesterdayOpen: .lookback
        case .onCall: .headset
        case .leave: .lounge
        case .sick: .sick
        case .holiday: .party
        case .weekend: .read
        case .paused: .meditate
        case .sourceBehind: .lookout
        case .nothingLogged: .shrug
        case .closedUnsealed: .scratch
        case .storeProblem: .worried
        }
    }
}
