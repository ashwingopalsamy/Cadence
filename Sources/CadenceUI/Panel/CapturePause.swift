// Pause capture until a time (docs/SPEC.md sections 4.1 and 4.2). The pause itself is `AppState.signals.paused`;
// this keeps the time it ends, so the panel can say "Capture paused until 15:00." and capture resumes on its own.
import Foundation
import Observation

@MainActor @Observable
public final class CapturePause {
    @ObservationIgnored private let app: AppState
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// When capture resumes on its own. Nil while not paused, or paused with no end.
    public private(set) var until: Date?
    /// Told the new end on every change (nil on resume), so presence capture stops and starts with it.
    @ObservationIgnored public var onChange: (@MainActor (Date?) -> Void)?

    public init(app: AppState) {
        self.app = app
    }

    /// Picks up a pause that was running when the app last quit, so a relaunch never resumes capture early.
    public func restore(until end: Date?) {
        guard let end, end > app.now else { return }
        pause(until: end)
    }

    /// The time the menu offers: the next whole hour, at least an hour away. At 13:40 that is 15:00.
    public static func suggestedEnd(after now: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return calendar.date(byAdding: .hour, value: 2, to: hour) ?? now
    }

    public func pause(until end: Date) {
        until = end
        app.signals.paused = true
        onChange?(end)
        timer?.cancel()
        let delay = max(0, end.timeIntervalSince(app.now))
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.resume()
        }
    }

    public func resume() {
        timer?.cancel()
        timer = nil
        until = nil
        app.signals.paused = false
        onChange?(nil)
    }
}
