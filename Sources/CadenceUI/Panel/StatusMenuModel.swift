// The status item's right-click menu as data (docs/SPEC.md section 4.1): Log something, the day's next step, Open
// Cadence, Pause or Resume capture, Not working today, Settings and Quit. Items that do not apply are left out.
import CadenceCore

public enum StatusMenuItem: Sendable, Equatable {
    case logSomething
    /// Plan your day, Plan today or Wrap up.
    case nextStep(PanelAction)
    case openCadence
    /// "Pause capture until 15:00".
    case pause(until: String)
    case resume
    /// A submenu of Leave, Sick and Holiday.
    case notWorkingToday
    case settings
    case quit
    case separator

    public var title: String {
        switch self {
        case .logSomething: String(localized: "Log something")
        case .nextStep(let action):
            // The menu names the step; the open count belongs to the panel.
            if case .wrapUp = action { String(localized: "Wrap up") } else { action.title }
        case .openCadence: String(localized: "Open Cadence")
        case .pause(let until): String(localized: "Pause capture until \(until)")
        case .resume: String(localized: "Resume capture")
        case .notWorkingToday: String(localized: "Not working today")
        case .settings: String(localized: "Settings\u{2026}")
        case .quit: String(localized: "Quit Cadence")
        case .separator: ""
        }
    }

    /// The days off the submenu offers, in order.
    public static let daysOff: [(DayStory.DayOff, String)] = [(.leave, String(localized: "Leave")), (.sick, String(localized: "Sick")), (.holiday, String(localized: "Holiday"))]

    /// The menu for a state. `content` is the panel's, so the menu and the panel agree on the next step and on
    /// whether a day off can be declared.
    public static func items(_ content: PanelContent, paused: Bool, pauseUntil: String) -> [StatusMenuItem] {
        let problem = content.state == .storeProblem
        var items: [StatusMenuItem] = []
        if !problem { items.append(.logSomething) }
        if let action = content.action {
            switch action {
            case .planDay, .planToday, .wrapUp: items.append(.nextStep(action))
            case .finishSetup, .sealAsEmpty, .lastWeekRecap, .fix: break
            }
        }
        items.append(.openCadence)
        var middle: [StatusMenuItem] = []
        if paused { middle.append(.resume) } else if !problem { middle.append(.pause(until: pauseUntil)) }
        if content.showsDayOff { middle.append(.notWorkingToday) }
        if !middle.isEmpty { items += [.separator] + middle }
        items += [.separator, .settings, .quit]
        return items
    }
}
