import CadenceCore
import Foundation

/// What only the app knows about the day, added on top of the store when the story is told (docs/SPEC.md
/// section 5.2): capture paused by you, a source that feeds the count and is behind, an import that is running,
/// and whether setup has been finished.
public struct AppSignals: Sendable, Equatable {
    public var paused: Bool
    public var behind: DayStory.Behind?
    public var importing: DayStory.Import?
    public var setupFinished: Bool

    public init(paused: Bool = false, behind: DayStory.Behind? = nil, importing: DayStory.Import? = nil, setupFinished: Bool = true) {
        self.paused = paused
        self.behind = behind
        self.importing = importing
        self.setupFinished = setupFinished
    }
}

extension DayLoad {
    /// The one story every surface tells, or nil while nothing has been read yet.
    ///
    /// A store that does not exist yet is a first run, not a problem. Any other failure is the store problem,
    /// which outranks everything else because nothing else can be trusted.
    public func story(signals: AppSignals, at now: Date, today: LocalDate) -> DayStory? {
        switch self {
        case .loading:
            return nil
        case .failed(let failure):
            var input = DayStory.Input(date: today)
            if failure.kind == .missing { input.firstRun = true } else { input.storeProblem = true }
            return DayStory(input)
        case .loaded(let state):
            var input = state.context?.storyInput(at: now) ?? DayStory.Input(date: state.day)
            input.paused = signals.paused
            input.behind = signals.behind
            input.importing = signals.importing
            input.firstRun = !signals.setupFinished
            return DayStory(input)
        }
    }
}
