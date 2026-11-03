// The global shortcuts (docs/SPEC.md section 4.8): one value Settings can change later, and the clash a failed
// registration reports. Pure: the Carbon registrar lives in the app, and tests use a fake one.
import Foundation

/// One global shortcut.
public struct HotkeyBinding: Sendable, Hashable {
    public enum Action: String, Sendable, Hashable, CaseIterable {
        /// `⌃⌥L`: the capture bar.
        case capture
        /// `⌃⌥N`: the capture bar with the kind set to note.
        case quickNote
        /// `⌃⌥D`: discreet mode on or off.
        case discreet
    }

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var action: Action
    /// The virtual key code, as `RegisterEventHotKey` takes it.
    public var keyCode: UInt32
    /// The key as printed on it.
    public var key: String
    public var modifiers: Modifiers

    public init(action: Action, keyCode: UInt32, key: String, modifiers: Modifiers) {
        self.action = action
        self.keyCode = keyCode
        self.key = key
        self.modifiers = modifiers
    }

    /// "⌃⌥L", with the modifiers in the order macOS prints them.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }
}

/// Every global shortcut in one value, so Settings can replace them together.
public struct HotkeyBindings: Sendable, Hashable {
    public var capture: HotkeyBinding
    public var quickNote: HotkeyBinding
    public var discreet: HotkeyBinding

    public init(capture: HotkeyBinding, quickNote: HotkeyBinding, discreet: HotkeyBinding) {
        self.capture = capture
        self.quickNote = quickNote
        self.discreet = discreet
    }

    /// ANSI key codes: L is 37, N is 45, D is 2.
    public static let standard = HotkeyBindings(
        capture: HotkeyBinding(action: .capture, keyCode: 37, key: "L", modifiers: [.control, .option]),
        quickNote: HotkeyBinding(action: .quickNote, keyCode: 45, key: "N", modifiers: [.control, .option]),
        discreet: HotkeyBinding(action: .discreet, keyCode: 2, key: "D", modifiers: [.control, .option]))

    public var all: [HotkeyBinding] { [capture, quickNote, discreet] }
}

/// A shortcut that could not be registered, most often because another app holds it.
public struct HotkeyClash: Sendable, Hashable {
    public var binding: HotkeyBinding
    /// The status the registrar returned.
    public var status: Int32

    public init(binding: HotkeyBinding, status: Int32) {
        self.binding = binding
        self.status = status
    }

    /// What Settings shows (section 4.8).
    public var message: String {
        String(localized: "\(binding.display) is already used by another app. Pick another shortcut, or use the menu-bar icon.")
    }
}

/// Registers one shortcut with the system. Returns 0 on success, or the status of the failure.
@MainActor
public protocol HotkeyRegistrar: AnyObject {
    func register(_ binding: HotkeyBinding, id: UInt32) -> Int32
    func unregister(id: UInt32)
}

/// Holds the registered shortcuts and turns a press into its action.
@MainActor
public final class HotkeyCenter {
    public private(set) var bindings: HotkeyBindings?
    /// The shortcuts that did not register, for Settings.
    public private(set) var clashes: [HotkeyClash] = []

    private let registrar: any HotkeyRegistrar
    private var registered: [UInt32: HotkeyBinding.Action] = [:]

    public init(registrar: any HotkeyRegistrar) {
        self.registrar = registrar
    }

    /// Replaces every shortcut with `bindings`. Each registers on its own, so one clash leaves the others working.
    @discardableResult
    public func apply(_ bindings: HotkeyBindings) -> [HotkeyClash] {
        for id in registered.keys.sorted() { registrar.unregister(id: id) }
        registered = [:]
        clashes = []
        for binding in bindings.all {
            let id = Self.id(of: binding.action)
            let status = registrar.register(binding, id: id)
            if status == 0 {
                registered[id] = binding.action
            } else {
                clashes.append(HotkeyClash(binding: binding, status: status))
            }
        }
        self.bindings = bindings
        return clashes
    }

    /// The action of a press, by the id it was registered with.
    public func action(for id: UInt32) -> HotkeyBinding.Action? { registered[id] }

    static func id(of action: HotkeyBinding.Action) -> UInt32 {
        UInt32(HotkeyBinding.Action.allCases.firstIndex(of: action) ?? 0) + 1
    }
}
