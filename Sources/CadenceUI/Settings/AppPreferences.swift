// The app's own choices, kept in UserDefaults because they are about this Mac's surfaces and not about the log
// (docs/SPEC.md sections 4.6 to 4.8 and 5.6). Everything about the log itself lives in config.json.
import Foundation

public struct AppPreferences: Sendable, Equatable {
    /// Tempo in the window and the panel. Discreet mode hides it either way.
    public var showTempo: Bool
    /// The streak, which only ever appears in Insights (section 5.4).
    public var showStreak: Bool
    /// The `agent.logged` sound, off until asked (section 5.6).
    public var agentSound: Bool
    /// Plan and wrap-up reminders on Saturday and Sunday too.
    public var remindOnWeekends: Bool
    /// When titles are on in notifications, the lock screen still shows counts only.
    public var hideTitlesOnLockScreen: Bool
    /// The global shortcuts (section 4.8).
    public var hotkeys: HotkeyBindings
    /// First run was finished. `AppSignals.setupFinished` reads it.
    public var setupFinished: Bool

    public init(
        showTempo: Bool = true, showStreak: Bool = true, agentSound: Bool = false, remindOnWeekends: Bool = false,
        hideTitlesOnLockScreen: Bool = true, hotkeys: HotkeyBindings = .standard, setupFinished: Bool = false
    ) {
        self.showTempo = showTempo
        self.showStreak = showStreak
        self.agentSound = agentSound
        self.remindOnWeekends = remindOnWeekends
        self.hideTitlesOnLockScreen = hideTitlesOnLockScreen
        self.hotkeys = hotkeys
        self.setupFinished = setupFinished
    }
}

/// Reads and writes `AppPreferences`. A key that was never written reads as its default.
public struct PreferenceStore {
    public enum Key {
        public static let showTempo = "cadence.showTempo"
        public static let showStreak = "cadence.showStreak"
        public static let agentSound = "cadence.sound.agentLogged"
        public static let remindOnWeekends = "cadence.reminders.weekends"
        public static let hideTitlesOnLockScreen = "cadence.privacy.hideTitlesOnLockScreen"
        public static let hotkeys = "cadence.hotkeys"
        public static let setupFinished = "cadence.setupFinished"
    }

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppPreferences {
        let fallback = AppPreferences()
        func flag(_ key: String, _ value: Bool) -> Bool { defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key) }
        return AppPreferences(
            showTempo: flag(Key.showTempo, fallback.showTempo),
            showStreak: flag(Key.showStreak, fallback.showStreak),
            agentSound: flag(Key.agentSound, fallback.agentSound),
            remindOnWeekends: flag(Key.remindOnWeekends, fallback.remindOnWeekends),
            hideTitlesOnLockScreen: flag(Key.hideTitlesOnLockScreen, fallback.hideTitlesOnLockScreen),
            hotkeys: Self.hotkeys(from: defaults.dictionary(forKey: Key.hotkeys)) ?? fallback.hotkeys,
            setupFinished: flag(Key.setupFinished, fallback.setupFinished))
    }

    public func save(_ preferences: AppPreferences) {
        defaults.set(preferences.showTempo, forKey: Key.showTempo)
        defaults.set(preferences.showStreak, forKey: Key.showStreak)
        defaults.set(preferences.agentSound, forKey: Key.agentSound)
        defaults.set(preferences.remindOnWeekends, forKey: Key.remindOnWeekends)
        defaults.set(preferences.hideTitlesOnLockScreen, forKey: Key.hideTitlesOnLockScreen)
        defaults.set(Self.dictionary(preferences.hotkeys), forKey: Key.hotkeys)
        defaults.set(preferences.setupFinished, forKey: Key.setupFinished)
    }

    /// For `AppSignals.setupFinished`.
    public var setupFinished: Bool { load().setupFinished }

    static func dictionary(_ bindings: HotkeyBindings) -> [String: Any] {
        var out: [String: Any] = [:]
        for binding in bindings.all {
            out[binding.action.rawValue] = ["keyCode": Int(binding.keyCode), "key": binding.key, "modifiers": binding.modifiers.rawValue]
        }
        return out
    }

    /// Nil unless every action is present and well formed, so a damaged value falls back to the standard keys.
    static func hotkeys(from dictionary: [String: Any]?) -> HotkeyBindings? {
        guard let dictionary else { return nil }
        func binding(_ action: HotkeyBinding.Action) -> HotkeyBinding? {
            guard let entry = dictionary[action.rawValue] as? [String: Any], let code = entry["keyCode"] as? Int,
                let key = entry["key"] as? String, !key.isEmpty, let modifiers = entry["modifiers"] as? Int,
                let keyCode = UInt32(exactly: code)
            else { return nil }
            return HotkeyBinding(action: action, keyCode: keyCode, key: key, modifiers: .init(rawValue: modifiers))
        }
        guard let capture = binding(.capture), let note = binding(.quickNote), let discreet = binding(.discreet) else { return nil }
        return HotkeyBindings(capture: capture, quickNote: note, discreet: discreet)
    }
}
