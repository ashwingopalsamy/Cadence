import CadenceCore
import Foundation

/// What the notification plan needs beyond today: the profile and the days ahead that were declared leave, holiday or
/// a weekend worked. Read off the main thread, on a read-only connection, like the day itself.
public struct NotificationHorizon: Sendable, Equatable {
    public var config: Config
    public var declared: [LocalDate: DayKind]

    public init(config: Config, declared: [LocalDate: DayKind]) {
        self.config = config
        self.declared = declared
    }
}

public struct NotificationHorizonLoader: Sendable {
    public let location: StoreLocation
    public let clock: any Clock
    /// How many days ahead are read. Seven workdays fit in it unless more than three weeks are leave.
    public let days: Int

    public init(location: StoreLocation, clock: any Clock, days: Int = 35) {
        self.location = location
        self.clock = clock
        self.days = days
    }

    /// Never throws and never writes. A missing or unreadable config means the defaults; a store that cannot be
    /// opened means nothing is known to be declared, and the day read says why.
    public func load() -> NotificationHorizon {
        let fallback = TimeZone.current.identifier
        guard case .found(let roots) = location else {
            return NotificationHorizon(config: .defaults(timezone: fallback), declared: [:])
        }
        let config = (try? ConfigStore.load(from: roots.config, fallbackZone: fallback))?.0 ?? .defaults(timezone: fallback)
        var declared: [LocalDate: DayKind] = [:]
        if FileManager.default.fileExists(atPath: roots.database.path) {
            let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
            if let store = try? SQLiteStore(path: roots.database.path, clock: clock, ids: ids, readOnly: true) {
                let zone = TimeZone(identifier: config.profile.timezone) ?? .current
                let today = config.dayBoundary.day(of: clock.now(), in: zone)
                for offset in -1..<days {
                    let day = today.adding(days: offset)
                    if let kind = try? store.declaredKind(of: day) { declared[day] = kind }
                }
            }
        }
        return NotificationHorizon(config: config, declared: declared)
    }
}

extension NotificationInput {
    /// The input from what the horizon read and the day the model last read. `reviewsWaiting` is for a source that
    /// knows; with none it stays unknown and the plan prompt does not mention reviews.
    public init(
        horizon: NotificationHorizon, now: Date, state: DayState?, reviewsWaiting: Int? = nil,
        snoozed: [PlannedNotification] = [], skippedPlanDays: Set<LocalDate> = []
    ) {
        self.init(
            now: now, zone: TimeZone(identifier: horizon.config.profile.timezone) ?? .current,
            rules: DayRules(config: horizon.config), declared: horizon.declared, reminders: horizon.config.reminders,
            showTitles: horizon.config.privacy.notificationTitles,
            facts: state.map { NotificationFacts(state: $0, reviewsWaiting: reviewsWaiting) }, snoozed: snoozed,
            skippedPlanDays: skippedPlanDays)
    }
}
