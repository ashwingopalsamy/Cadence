// Stepping through earlier days in Today (docs/SPEC.md section 4.8): `←` and `→` go to the previous or next day, never
// past today. An earlier day is read once on arrival, off the main thread, and again whenever the store changes while
// it is shown. Leaving Today or crossing the day boundary returns to the live day.
import CadenceCore
import Foundation
import Observation

@MainActor @Observable
public final class DayBrowser {
    /// The earlier day shown, or nil for the live day.
    public private(set) var shown: LocalDate?
    /// The last read of an earlier day: `.loading` before the first one arrives. A step keeps the last read on screen
    /// until the next one lands, so the page never blanks between two earlier days.
    public private(set) var load: DayLoad = .loading
    /// Counts finished reads, so a caller can wait for one.
    public private(set) var reads = 0

    /// The live day when stepping began. When the live day moves on, the earlier day is put away.
    @ObservationIgnored private var anchor: LocalDate?
    @ObservationIgnored private let read: (@Sendable (LocalDate) async -> DayContext?)?
    @ObservationIgnored private var generation = 0

    /// `read` returns nil when the day cannot be read. Without one, Today stays on the live day.
    public init(read: (@Sendable (LocalDate) async -> DayContext?)? = nil) {
        self.read = read
    }

    public convenience init(reader: StoreReader) {
        self.init(read: { await reader.context(on: $0) })
    }

    public var canStep: Bool { read != nil }

    /// The earlier day to show while `today` is the live day, or nil for the live day.
    public func shown(today: LocalDate) -> LocalDate? {
        anchor == today ? shown : nil
    }

    /// The context of the earlier day shown, as last read. Nil for the live day, while nothing has been read for the day,
    /// and when the read failed.
    func context(today: LocalDate) -> DayContext? {
        guard let day = shown(today: today), case .loaded(let state) = load, state.day == day else { return nil }
        return state.context
    }

    /// The earlier day shown, when it has been reopened and is not sealed again: it can be changed, so a line logged in
    /// Today goes onto it. Nil for the live day and for an earlier day that is sealed or was never reopened.
    public func reopenedDay(today: LocalDate) -> LocalDate? {
        context(today: today)?.isReopened == true ? shown(today: today) : nil
    }

    /// The plan of the earlier day shown, for what VoiceOver says when one of its tasks is ticked.
    public func shownPlan(today: LocalDate) -> [PlanTask]? {
        context(today: today)?.plan
    }

    /// One day back for a negative `by`, forward for a positive one. Reaching today returns to the live day.
    public func step(by days: Int, today: LocalDate) {
        guard canStep else { return }
        let target = (shown(today: today) ?? today).adding(days: days)
        guard target < today else {
            backToToday()
            return
        }
        anchor = today
        shown = target
        fetch()
    }

    public func backToToday() {
        generation += 1
        anchor = nil
        shown = nil
        load = .loading
    }

    /// The live day is now `today`: an earlier day picked under another live day is put away.
    public func follow(today: LocalDate) {
        if anchor != nil, anchor != today { backToToday() }
    }

    /// Reads the shown day again, after the store changed.
    public func refresh() {
        if shown != nil { fetch() }
    }

    private func fetch() {
        guard let read, let day = shown else { return }
        generation += 1
        let mine = generation
        Task {
            let context = await read(day)
            // A later step or a return to today has replaced this read.
            guard mine == generation else { return }
            if let context {
                load = .loaded(DayState(context: context))
            } else {
                load = .failed(StoreFailure(detail: String(localized: "Cadence could not read \(day.description)")))
            }
            reads += 1
        }
    }
}
