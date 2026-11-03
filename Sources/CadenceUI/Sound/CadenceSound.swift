// The sound player (docs/SPEC.md section 5.6): six short sounds at Off, Subtle or Full, never on a muted output.
//
// Focus. The spec says never when a Focus mode asks for silence. The app cannot read Focus: INFocusStatusCenter
// needs the Communication Notifications entitlement, which the app must not add (section 8.3), and the other
// routes, such as reading the Do Not Disturb assertions file, fall outside the sandbox. So this player checks the
// system output (mute, or volume at zero) and nothing else. Notifications are posted at the active interruption
// level (section 4.7), which Focus filters by itself; a sound played here is the app's own audio, which Focus does
// not silence. Off stays one setting away.
import AVFoundation
import AudioToolbox
import CadenceCore
import CoreAudio
import Foundation

/// The six sounds. The raw value is the file name in the app's Sounds folder, and the name in the spec table.
public enum CadenceSound: String, CaseIterable, Sendable {
    case dayStart = "day.start"
    case captureSaved = "capture.saved"
    case planCommitted = "plan.committed"
    case ringClosed = "ring.closed"
    case streakMilestone = "streak.milestone"
    case agentLogged = "agent.logged"
}

/// What the person chose. The level is the `sounds` key of config.json; `agentLogged` is the separate switch for
/// the sound of an agent logging work, off until asked.
public struct SoundSettings: Sendable, Equatable {
    public var level: Config.Sounds
    public var agentLogged: Bool

    public init(level: Config.Sounds = .subtle, agentLogged: Bool = false) {
        self.level = level
        self.agentLogged = agentLogged
    }
}

/// Which sounds play at which level, as pure logic.
public enum SoundPolicy {
    /// The files are normalised near -18 LUFS, so Full plays them as they are and Subtle plays them 9 dB under.
    public static let subtleVolume: Float = 0.35
    public static let fullVolume: Float = 1.0

    /// The volume to play `sound` at, or nil when it stays silent.
    public static func volume(for sound: CadenceSound, settings: SoundSettings) -> Float? {
        if sound == .agentLogged && !settings.agentLogged { return nil }
        switch settings.level {
        case .off: return nil
        case .subtle: return subtleVolume
        case .full: return fullVolume
        }
    }
}

/// What the default output device says about being heard.
struct OutputReading: Equatable {
    var deviceExists = true
    /// The mute flags the device offers: its main one, or one per channel.
    var mutes: [Bool] = []
    /// The volumes the device offers: its main one, or one per channel.
    var volumes: [Float] = []

    /// Silent when there is no device, every mute flag is set, or every volume is zero. A device with neither
    /// control (some HDMI and USB outputs) cannot be read, so it counts as audible.
    var isSilent: Bool {
        if !deviceExists { return true }
        if !mutes.isEmpty && mutes.allSatisfy({ $0 }) { return true }
        if !volumes.isEmpty && volumes.allSatisfy({ $0 == 0 }) { return true }
        return false
    }
}

/// The system output, read through the audio hardware properties. Reading them needs no entitlement.
enum SystemOutput {
    static func isMuted() -> Bool { read().isSilent }

    static func read() -> OutputReading {
        guard let device = defaultOutputDevice() else { return OutputReading(deviceExists: false) }
        var reading = OutputReading()
        reading.mutes = values(device: device, selector: kAudioDevicePropertyMute) { (raw: UInt32) in raw != 0 }
        // The virtual main volume is what the volume keys move; fall back to the device's own scalar volume.
        reading.volumes = values(device: device, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume) { (raw: Float32) in raw }
        if reading.volumes.isEmpty {
            reading.volumes = values(device: device, selector: kAudioDevicePropertyVolumeScalar) { (raw: Float32) in raw }
        }
        return reading
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != AudioObjectID(kAudioObjectUnknown) ? device : nil
    }

    /// The property on the main element if the device has one, otherwise on channels 1 and 2.
    private static func values<Raw, Value>(
        device: AudioObjectID, selector: AudioObjectPropertySelector, _ convert: (Raw) -> Value
    ) -> [Value] where Raw: BitwiseCopyable & Numeric {
        for elements in [[kAudioObjectPropertyElementMain], [1, 2]] as [[AudioObjectPropertyElement]] {
            let found = elements.compactMap { element -> Value? in
                var address = AudioObjectPropertyAddress(
                    mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                guard AudioObjectHasProperty(device, &address) else { return nil }
                var raw: Raw = 0
                var size = UInt32(MemoryLayout<Raw>.size)
                guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &raw) == noErr else { return nil }
                return convert(raw)
            }
            if !found.isEmpty { return found }
        }
        return []
    }
}

/// One preloaded sound. A protocol so the player's choices can be tested without starting audio.
@MainActor
protocol SoundVoice: AnyObject {
    /// Starts the sound from its beginning at `volume`; false when it did not start.
    func play(volume: Float) -> Bool
}

@MainActor
final class AudioVoice: SoundVoice {
    private let player: AVAudioPlayer

    init?(url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        self.player = player
    }

    func play(volume: Float) -> Bool {
        player.volume = volume
        player.currentTime = 0
        return player.play()
    }
}

/// Plays the six sounds: `player.play(.ringClosed)`. One AVAudioPlayer per sound, loaded once from the Sounds
/// folder of the bundle. A missing or unreadable file means that sound is silent; nothing is reported or thrown.
@MainActor
public final class CadenceSoundPlayer {
    public var settings: SoundSettings
    private let voices: [CadenceSound: any SoundVoice]
    private let outputMuted: @MainActor () -> Bool

    init(settings: SoundSettings, outputMuted: @escaping @MainActor () -> Bool, voices: [CadenceSound: any SoundVoice]) {
        self.settings = settings
        self.outputMuted = outputMuted
        self.voices = voices
    }

    public convenience init(settings: SoundSettings = SoundSettings(), bundle: Bundle = .main) {
        var voices: [CadenceSound: any SoundVoice] = [:]
        for sound in CadenceSound.allCases {
            guard let url = bundle.url(forResource: sound.rawValue, withExtension: "caf", subdirectory: "Sounds"),
                let voice = AudioVoice(url: url)
            else { continue }
            voices[sound] = voice
        }
        self.init(settings: settings, outputMuted: { SystemOutput.isMuted() }, voices: voices)
    }

    /// The sounds whose files were found and read.
    public var loadedSounds: Set<CadenceSound> { Set(voices.keys) }

    /// Plays `sound` if the level allows it, the output is not muted and its file loaded. Returns whether it started.
    @discardableResult
    public func play(_ sound: CadenceSound) -> Bool {
        guard let voice = voices[sound], let volume = SoundPolicy.volume(for: sound, settings: settings) else { return false }
        guard !outputMuted() else { return false }
        return voice.play(volume: volume)
    }
}
