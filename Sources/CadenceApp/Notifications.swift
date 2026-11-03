// Notifications (docs/SPEC.md section 4.7): the thin UserNotifications side. What to say, when, and what a button does
// are pure and tested in CadenceUI (`NotificationPlan`); this file registers the categories, keeps the system's list
// of pending requests equal to the plan, and hands taps and buttons back to the app.
import CadenceCore
import CadenceUI
import Foundation
import Observation
import UserNotifications

@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let clock: any Clock
    private let loader: NotificationHorizonLoader
    /// Discreet mode, set by the app: notifications show counts only while it is on.
    var discreet = false
    private let onRoute: @MainActor (NotificationRoute) -> Void

    /// Whether the system lets the app show notifications, as of the last look. A denial is not an error here: the
    /// "Notifications are off" screen of section 4.6 reads it, and the menu-bar mark still shows when a wrap-up is due.
    private(set) var access: NotificationAccess = .notDetermined

    private var latestState: DayState?
    /// The calendar notifications this process has asked the system for.
    private var scheduled: [String: PlannedNotification] = [:]
    /// "In 30 min" put-offs, by identifier. One per category and day.
    private var snoozed: [String: PlannedNotification] = [:]
    private var skippedPlanDays: Set<LocalDate> = []
    /// Sources already told about, until they sync again, so a failing source is one notice and never a nag.
    private var noticed: Set<String> = []
    private var clearedLeftovers = false
    private var requestedAccess = false
    private var scheduling = false
    private var scheduleAgain = false

    /// Nil outside an app bundle (`swift run`): `UNUserNotificationCenter` aborts the process there.
    init?(clock: any Clock, location: StoreLocation, onRoute: @escaping @MainActor (NotificationRoute) -> Void) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        center = UNUserNotificationCenter.current()
        self.clock = clock
        loader = NotificationHorizonLoader(location: location, clock: clock)
        self.onRoute = onRoute
        super.init()
        center.delegate = self
        center.setNotificationCategories(Self.categories())
    }

    // MARK: Permission

    /// Asks the system once, when it has not been asked, and says what it answered. A denial, or a system that cannot
    /// show this app's notifications, is `.denied`.
    func authorize() async -> NotificationAccess {
        var current = await currentAccess()
        if current == .notDetermined, !requestedAccess {
            requestedAccess = true
            let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
            current = granted ? .allowed : .denied
        }
        access = current
        return current
    }

    private func currentAccess() async -> NotificationAccess {
        let status = await center.notificationSettings().authorizationStatus
        let now: NotificationAccess
        switch status {
        case .notDetermined: now = .notDetermined
        case .authorized, .provisional, .ephemeral: now = .allowed
        default: now = .denied
        }
        access = now
        return now
    }

    // MARK: What the clock and the model tell it

    /// A moment of the day clock. The morning boundary and a wake or a change of zone or clock reschedule the next 7
    /// workdays; the plan prompt is shown when its moment comes. The wrap-up reminders are the system's: they were
    /// scheduled ahead as calendar triggers and need nothing at the moment.
    func clockEvent(_ event: DayClock.Event, state: DayState?) {
        latestState = state
        switch event {
        case .moment(let moment):
            switch moment.kind {
            case .boundary: refresh(state: state)
            case .planPrompt: showPlanPrompt()
            case .wrapReminder, .graceClosed: break
            }
        case .changed:
            refresh(state: state)
        }
    }

    /// Recomputes the schedule each time the model publishes a read, so today's counts, a seal, a committed plan or a
    /// new leave day reach the system. Only what changed is touched.
    func follow(_ model: DayModel) {
        withObservationTracking {
            _ = model.load
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh(state: model.state)
                self?.follow(model)
            }
        }
    }

    /// Makes the system's pending list equal to the plan. Calls that arrive while one is running collapse into one more.
    func refresh(state: DayState?) {
        latestState = state
        guard !scheduling else {
            scheduleAgain = true
            return
        }
        scheduling = true
        Task {
            repeat {
                scheduleAgain = false
                await reschedule()
            } while scheduleAgain
            scheduling = false
        }
    }

    private func reschedule() async {
        guard await currentAccess() == .allowed else {
            // Nothing can be shown, so nothing is left waiting; the next look after a change in Settings fills it again.
            center.removePendingNotificationRequests(withIdentifiers: Array(scheduled.keys))
            scheduled = [:]
            return
        }
        let input = await currentInput()
        let desired = NotificationPlan.scheduled(input)
        if !clearedLeftovers {
            // Every pending request is this app's, and an earlier launch may have left some that no longer apply.
            center.removeAllPendingNotificationRequests()
            clearedLeftovers = true
        }
        let changes = NotificationPlan.changes(from: Array(scheduled.values), to: desired)
        center.removePendingNotificationRequests(withIdentifiers: changes.remove)
        for id in changes.remove { scheduled[id] = nil }
        for notification in changes.add {
            do {
                try await center.add(Self.request(notification))
                scheduled[notification.id] = notification
            } catch {
                // Not recorded, so the next refresh tries again.
            }
        }
        let wanted = Set(desired.map(\.id))
        snoozed = snoozed.filter { wanted.contains($0.key) }
    }

    private func currentInput() async -> NotificationInput {
        let loader = loader
        let horizon = await Task.detached(priority: .utility) { loader.load() }.value
        var input = NotificationInput(
            horizon: horizon, now: clock.now(), state: latestState, snoozed: Array(snoozed.values),
            skippedPlanDays: skippedPlanDays)
        // Discreet mode is for screen sharing, so it overrides "Show task titles" (section 6.7).
        if discreet { input.showTitles = false }
        return input
    }

    // MARK: Notices shown now

    private func showPlanPrompt() {
        Task {
            guard await currentAccess() == .allowed, let prompt = NotificationPlan.planPrompt(await currentInput()) else { return }
            try? await center.add(Self.request(prompt))
        }
    }

    /// A source has not synced since `lastSync`. At three hours it is one notice; it is not repeated until the source
    /// has synced again and fallen behind again.
    func sourceBehind(_ source: String, since lastSync: Date) {
        let hours = NotificationPlan.hoursBehind(since: lastSync, now: clock.now())
        guard !noticed.contains(source), let notice = NotificationPlan.sourceBehind(source: source, hours: hours) else { return }
        noticed.insert(source)
        Task {
            guard await currentAccess() == .allowed else { return }
            try? await center.add(Self.request(notice))
        }
    }

    /// The source synced again: its notice is withdrawn and a later failure may speak again.
    func sourceRecovered(_ source: String) {
        noticed.remove(source)
        center.removeDeliveredNotifications(withIdentifiers: ["source.\(source)"])
    }

    // MARK: Replies

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let day = content.userInfo["day"] as? String
        let kind: NotificationResponse
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier: kind = .tap
        case UNNotificationDismissActionIdentifier: kind = .dismiss
        default: kind = .action(response.actionIdentifier)
        }
        completionHandler()
        Task { @MainActor in self.handle(category: category, response: kind, day: day) }
    }

    /// The app is a menu-bar app and counts as in front whenever its panel is up, so a notification still shows.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    private func handle(category: String, response: NotificationResponse, day: String?) {
        guard let reply = NotificationPlan.reply(category: category, response: response, day: day) else { return }
        switch reply {
        case .route(let route):
            onRoute(route)
        case .snooze(let category, let day):
            Task {
                let input = await currentInput()
                if let later = NotificationPlan.snooze(category, day: day, input: input) { snoozed[later.id] = later }
                refresh(state: latestState)
            }
        case .skipToday(let day):
            skippedPlanDays.insert(day)
            refresh(state: latestState)
        }
    }

    // MARK: The system's side

    private static func categories() -> Set<UNNotificationCategory> {
        Set(
            NotificationCategory.allCases.map { category in
                let actions = NotificationAction.actions(for: category).map { action in
                    // The buttons that open something bring the app forward; putting off and skipping do not.
                    let opens = [NotificationAction.planNow, .wrapUp, .openSources].contains(action)
                    return UNNotificationAction(
                        identifier: action.rawValue, title: action.title, options: opens ? [.foreground] : [])
                }
                return UNNotificationCategory(identifier: category.rawValue, actions: actions, intentIdentifiers: [], options: [])
            })
    }

    private static func request(_ notification: PlannedNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = notification.category.rawValue
        content.threadIdentifier = notification.category.rawValue
        // Time-sensitive delivery needs a restricted entitlement, so the app does not use it (section 4.7).
        content.interruptionLevel = .active
        if let day = notification.day { content.userInfo = ["day": day.description] }
        let trigger = notification.dateComponents.map { UNCalendarNotificationTrigger(dateMatching: $0, repeats: false) }
        return UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger)
    }
}
