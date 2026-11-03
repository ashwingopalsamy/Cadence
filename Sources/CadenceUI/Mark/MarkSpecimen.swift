// Every state of the menu-bar mark with its name from docs/SPEC.md section 4.1, in the order of the table there,
// for the snapshot sheet and the tests. Water states show a day part done; plan settled shows the plan resolved.
import CadenceCore

public struct MarkSpecimen: Sendable, Identifiable {
    public let name: String
    /// Nil for discreet mode, which is not a day state.
    public let state: DayStory.State?
    public let form: MarkForm

    public var id: String { name }

    /// A plan part done, for every state whose water shows plan progress.
    public static let partLevel = 0.6

    public init(_ name: String, _ state: DayStory.State, level: Double? = nil) {
        let settled = state == .planSettled
        self.name = name
        self.state = state
        form = MarkForm(state: state, level: level ?? (settled ? 1 : Self.partLevel), allResolved: settled, discreet: false)
    }

    private init(discreet name: String) {
        self.name = name
        state = nil
        form = .discreet
    }

    /// The water states with nothing resolved yet, where the water is a meniscus. Plan settled cannot be empty.
    public static let empty: [MarkSpecimen] = all.compactMap { specimen in
        guard let state = specimen.state, state != .planSettled, specimen.form.water != nil else { return nil }
        return MarkSpecimen(specimen.name, state, level: 0)
    }

    public static let all: [MarkSpecimen] = [
        MarkSpecimen("First run", .firstRun),
        MarkSpecimen("First sync running", .firstSync),
        MarkSpecimen("Still learning", .learning),
        MarkSpecimen("Morning, not planned", .morning),
        MarkSpecimen("Planned, not started", .planned),
        MarkSpecimen("In rhythm", .inRhythm),
        MarkSpecimen("More than usual", .moreThanUsual),
        MarkSpecimen("Fewer than usual", .fewerThanUsual),
        MarkSpecimen("Plan settled", .planSettled),
        MarkSpecimen("Wrap-up due", .wrapUpDue),
        MarkSpecimen("Sealed", .sealed),
        MarkSpecimen("Edited after wrap-up", .editedAfterWrapUp),
        MarkSpecimen("Yesterday still open", .yesterdayOpen),
        MarkSpecimen("A day closed unsealed", .closedUnsealed),
        MarkSpecimen("On call", .onCall),
        MarkSpecimen("On leave", .leave),
        MarkSpecimen("Off sick", .sick),
        MarkSpecimen("Holiday", .holiday),
        MarkSpecimen("Weekend", .weekend),
        MarkSpecimen("Capture paused", .paused),
        MarkSpecimen("A source is behind", .sourceBehind),
        MarkSpecimen("Nothing logged by wrap-up", .nothingLogged),
        MarkSpecimen("Store problem", .storeProblem),
        MarkSpecimen(discreet: "Discreet mode"),
    ]
}
