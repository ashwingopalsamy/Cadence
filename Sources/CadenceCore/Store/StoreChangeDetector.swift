import Foundation

/// What one read of the store's change counter found.
public enum StoreReading: Sendable, Equatable {
    /// `PRAGMA data_version`, which changes when another connection commits.
    case version(Int64)
    /// The store could not be opened or read.
    case unreadable
}

/// Where the observer reads the change counter from.
public protocol StoreVersionSource: Sendable {
    func read() -> StoreReading
}

/// How often the observer looks (docs/SPEC.md sections 8.6 and 8.7, S6).
public struct StoreWatchTiming: Sendable, Equatable {
    /// Poll interval while a Cadence surface is on screen.
    public var visiblePoll: TimeInterval
    /// Poll interval otherwise.
    public var hiddenPoll: TimeInterval
    /// How long a burst of notifications is gathered into one check.
    public var coalesce: TimeInterval

    public init(visiblePoll: TimeInterval, hiddenPoll: TimeInterval, coalesce: TimeInterval) {
        self.visiblePoll = visiblePoll
        self.hiddenPoll = hiddenPoll
        self.coalesce = coalesce
    }

    /// 2 s visible and 30 s hidden are the spec's polling fallback. A burst of writes waits 200 ms for one
    /// check, which leaves the UI well inside one second of a CLI write.
    public static let standard = StoreWatchTiming(visiblePoll: 2, hiddenPoll: 30, coalesce: 0.2)

    func poll(visible: Bool) -> TimeInterval { visible ? visiblePoll : hiddenPoll }
}

/// The observer's decisions as a pure value: when to look at the store next and whether what it found
/// is a change worth a reload. It reads no clock and no database; the caller passes `now` and a reader,
/// so tests drive it with a scripted store and a hand-moved clock.
///
/// - A store-changed notification opens a coalescing window. Notifications inside the window add
///   nothing, so a burst of writes is one check, and steady writes cost at most one check per window.
/// - Polling is the fallback if a notification is lost: every `visiblePoll` seconds while visible,
///   every `hiddenPoll` otherwise. Showing the view checks at once.
/// - A check reloads only when the reading differs from the one before. The first check always does,
///   which doubles as the initial load. An unreadable store is a reading too: the move into and out
///   of it reloads once, so the error shows and clears, and a store that stays unreadable is quiet.
public struct StoreChangeDetector: Sendable {
    public let timing: StoreWatchTiming
    public private(set) var visible: Bool
    private var last: StoreReading?
    private var lastCheck: Date
    private var pollDue: Date
    private var signalDue: Date?

    /// The first check is due at `now`.
    public init(timing: StoreWatchTiming = .standard, visible: Bool = false, now: Date) {
        self.timing = timing
        self.visible = visible
        lastCheck = now
        pollDue = now
    }

    /// When the caller should next call `wake`.
    public var nextWake: Date {
        guard let signalDue else { return pollDue }
        return min(pollDue, signalDue)
    }

    /// A store-changed notification arrived.
    public mutating func signal(at now: Date) {
        if signalDue == nil { signalDue = now.addingTimeInterval(timing.coalesce) }
    }

    /// The view was shown or hidden. Showing it checks at once; hiding it backs off to the slow poll,
    /// and a check already pending still happens.
    public mutating func setVisible(_ visible: Bool, at now: Date) {
        guard visible != self.visible else { return }
        self.visible = visible
        // Before the first check there is nothing to back off from: that check is still due at once.
        guard last != nil else { return }
        pollDue = visible ? now : lastCheck.addingTimeInterval(timing.hiddenPoll)
    }

    /// Call when the timer fires. Returns true when the view should reload. Does nothing before `nextWake`.
    public mutating func wake(at now: Date, read: () -> StoreReading) -> Bool {
        guard now >= nextWake else { return false }
        signalDue = nil
        lastCheck = now
        pollDue = now.addingTimeInterval(timing.poll(visible: visible))
        let reading = read()
        defer { last = reading }
        return last != reading
    }
}
