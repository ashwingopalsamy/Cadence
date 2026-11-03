// Global shortcuts through Carbon's RegisterEventHotKey (docs/SPEC.md section 4.8). It works in the sandbox and
// needs no Accessibility or Input Monitoring permission (docs/SPIKES.md, S5). The bindings and the clash report are
// CadenceUI's `HotkeyCenter`; this file only talks to Carbon.
import AppKit
import Carbon.HIToolbox
import CadenceUI

@MainActor
final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    /// "CDNC", so a press from another registration in the process is never mistaken for ours.
    private static let signature = OSType(0x4344_4E43)

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let onPress: @MainActor (UInt32) -> Void

    init(onPress: @escaping @MainActor (UInt32) -> Void) {
        self.onPress = onPress
        installHandler()
    }

    func register(_ binding: HotkeyBinding, id: UInt32) -> Int32 {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode, Self.carbonModifiers(binding.modifiers), EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[id] = ref }
        return status
    }

    func unregister(id: UInt32) {
        guard let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    static func carbonModifiers(_ modifiers: HotkeyBinding.Modifiers) -> UInt32 {
        var value = 0
        if modifiers.contains(.control) { value |= controlKey }
        if modifiers.contains(.option) { value |= optionKey }
        if modifiers.contains(.shift) { value |= shiftKey }
        if modifiers.contains(.command) { value |= cmdKey }
        return UInt32(value)
    }

    /// One handler for every press. Carbon calls it on the main thread; the registrar travels as its user data.
    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == CarbonHotkeyRegistrar.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let pressed = id.id
                MainActor.assumeIsolated {
                    Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue().onPress(pressed)
                }
                return noErr
            }, 1, &spec, me, &handler)
    }
}

/// The app's shortcuts: registers the bindings and runs each press.
@MainActor
final class Hotkeys {
    private var registrar: CarbonHotkeyRegistrar?
    private(set) var center: HotkeyCenter?
    private let perform: @MainActor (HotkeyBinding.Action) -> Void

    init(perform: @escaping @MainActor (HotkeyBinding.Action) -> Void) {
        self.perform = perform
    }

    /// Registers `bindings` and returns the ones another app already holds, for Settings to show.
    @discardableResult
    func apply(_ bindings: HotkeyBindings = .standard) -> [HotkeyClash] {
        if center == nil {
            let registrar = CarbonHotkeyRegistrar { [weak self] id in
                guard let self, let action = self.center?.action(for: id) else { return }
                self.perform(action)
            }
            self.registrar = registrar
            center = HotkeyCenter(registrar: registrar)
        }
        let clashes = center?.apply(bindings) ?? []
        for clash in clashes {
            FileHandle.standardError.write(Data("hotkey: \(clash.message) (status \(clash.status))\n".utf8))
        }
        return clashes
    }
}
