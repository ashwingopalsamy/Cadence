import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// Which sounds play at which level, and that nothing plays on a muted output or without a file. No test here
/// starts audio: the player is given recording voices, and the shipped files are only loaded, never played.
@Suite struct CadenceSoundTests {
    static let moments: [CadenceSound] = [.dayStart, .captureSaved, .planCommitted, .ringClosed, .streakMilestone]

    // MARK: Level logic

    @Test func theSixSoundsAreNamedAsInTheSpecTable() {
        #expect(CadenceSound.allCases.map(\.rawValue)
            == ["day.start", "capture.saved", "plan.committed", "ring.closed", "streak.milestone", "agent.logged"])
    }

    @Test func subtleIsTheDefaultAndTheAgentSoundIsOffByDefault() {
        let settings = SoundSettings()
        #expect(settings.level == .subtle)
        #expect(settings.agentLogged == false)
    }

    @Test func offPlaysNothingWhateverTheAgentSetting() {
        for agent in [false, true] {
            let settings = SoundSettings(level: .off, agentLogged: agent)
            for sound in CadenceSound.allCases {
                #expect(SoundPolicy.volume(for: sound, settings: settings) == nil, "\(sound)")
            }
        }
    }

    @Test func subtlePlaysTheFiveMomentsAtTheSubtleVolume() {
        let settings = SoundSettings(level: .subtle)
        for sound in Self.moments {
            #expect(SoundPolicy.volume(for: sound, settings: settings) == SoundPolicy.subtleVolume, "\(sound)")
        }
    }

    @Test func fullPlaysTheFiveMomentsLouderThanSubtle() {
        let settings = SoundSettings(level: .full)
        for sound in Self.moments {
            #expect(SoundPolicy.volume(for: sound, settings: settings) == SoundPolicy.fullVolume, "\(sound)")
        }
        #expect(SoundPolicy.subtleVolume > 0)
        #expect(SoundPolicy.subtleVolume < SoundPolicy.fullVolume)
        #expect(SoundPolicy.fullVolume <= 1)
    }

    @Test func theAgentSoundIsSilentAtEveryLevelUntilItsOwnSettingIsOn() {
        for level in [Config.Sounds.subtle, .full] {
            #expect(SoundPolicy.volume(for: .agentLogged, settings: SoundSettings(level: level, agentLogged: false)) == nil)
        }
        #expect(SoundPolicy.volume(for: .agentLogged, settings: SoundSettings(level: .subtle, agentLogged: true))
            == SoundPolicy.subtleVolume)
        #expect(SoundPolicy.volume(for: .agentLogged, settings: SoundSettings(level: .full, agentLogged: true))
            == SoundPolicy.fullVolume)
    }

    @Test func theAgentSettingDoesNotSilenceTheOtherSounds() {
        let settings = SoundSettings(level: .full, agentLogged: false)
        for sound in Self.moments {
            #expect(SoundPolicy.volume(for: sound, settings: settings) == SoundPolicy.fullVolume, "\(sound)")
        }
    }

    // MARK: The player, with recording voices

    @MainActor final class RecordingVoice: SoundVoice {
        var volumes: [Float] = []
        var starts = true
        func play(volume: Float) -> Bool {
            volumes.append(volume)
            return starts
        }
    }

    @MainActor static func player(
        _ settings: SoundSettings, muted: @escaping @MainActor () -> Bool = { false }
    ) -> (CadenceSoundPlayer, [CadenceSound: RecordingVoice]) {
        var voices: [CadenceSound: RecordingVoice] = [:]
        for sound in CadenceSound.allCases { voices[sound] = RecordingVoice() }
        return (CadenceSoundPlayer(settings: settings, outputMuted: muted, voices: voices), voices)
    }

    @MainActor @Test func aSoundPlaysAtTheVolumeOfTheLevel() {
        let (player, voices) = Self.player(SoundSettings(level: .subtle))
        #expect(player.play(.ringClosed))
        #expect(voices[.ringClosed]?.volumes == [SoundPolicy.subtleVolume])
        player.settings.level = .full
        #expect(player.play(.ringClosed))
        #expect(voices[.ringClosed]?.volumes == [SoundPolicy.subtleVolume, SoundPolicy.fullVolume])
        #expect(voices[.dayStart]?.volumes == [])
    }

    @MainActor @Test func aMutedOutputPlaysNothing() {
        let (player, voices) = Self.player(SoundSettings(level: .full, agentLogged: true), muted: { true })
        for sound in CadenceSound.allCases {
            #expect(player.play(sound) == false, "\(sound)")
        }
        #expect(voices.values.allSatisfy { $0.volumes.isEmpty })
    }

    @MainActor @Test func unmutingMakesTheNextSoundPlay() {
        var muted = true
        let (player, voices) = Self.player(SoundSettings(level: .subtle), muted: { muted })
        #expect(player.play(.captureSaved) == false)
        muted = false
        #expect(player.play(.captureSaved))
        #expect(voices[.captureSaved]?.volumes == [SoundPolicy.subtleVolume])
    }

    @MainActor @Test func offNeverAsksTheOutputAndTheAgentSoundStaysSilentUntilAsked() {
        var asked = 0
        let (off, _) = Self.player(SoundSettings(level: .off, agentLogged: true), muted: { asked += 1; return false })
        #expect(off.play(.dayStart) == false)
        #expect(asked == 0)

        let (quiet, voices) = Self.player(SoundSettings(level: .subtle))
        #expect(quiet.play(.agentLogged) == false)
        #expect(voices[.agentLogged]?.volumes == [])
        quiet.settings.agentLogged = true
        #expect(quiet.play(.agentLogged))
        #expect(voices[.agentLogged]?.volumes == [SoundPolicy.subtleVolume])
    }

    @MainActor @Test func aVoiceThatCannotStartReportsItAndNothingElse() {
        let (player, voices) = Self.player(SoundSettings(level: .full))
        voices[.dayStart]?.starts = false
        #expect(player.play(.dayStart) == false)
        #expect(player.play(.captureSaved))
    }

    // MARK: Files

    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources", isDirectory: true)

    @MainActor @Test func missingFilesFailSilently() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-sound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let player = CadenceSoundPlayer(settings: SoundSettings(level: .full, agentLogged: true), bundle: Bundle(url: empty) ?? .main)
        #expect(player.loadedSounds.isEmpty)
        for sound in CadenceSound.allCases {
            #expect(player.play(sound) == false, "\(sound)")
        }
    }

    @MainActor @Test func theShippedFilesLoadFromTheSoundsFolderOfABundle() throws {
        // App/Resources has the same layout as Contents/Resources in the built app: a Sounds folder of .caf files.
        let bundle = try #require(Bundle(url: Self.resources))
        let player = CadenceSoundPlayer(settings: SoundSettings(level: .off), bundle: bundle)
        #expect(player.loadedSounds == Set(CadenceSound.allCases))
    }

    // MARK: What the system output says

    @Test func anOutputWithNoDeviceIsSilent() {
        #expect(OutputReading(deviceExists: false).isSilent)
    }

    @Test func aMutedMainElementSilencesAndAnUnmutedOneDoesNot() {
        #expect(OutputReading(mutes: [true]).isSilent)
        #expect(OutputReading(mutes: [false]).isSilent == false)
    }

    @Test func aDeviceWithOnlyChannelMutesIsSilentWhenEveryChannelIsMuted() {
        #expect(OutputReading(mutes: [true, true]).isSilent)
        #expect(OutputReading(mutes: [true, false]).isSilent == false)
    }

    @Test func volumeAtZeroIsSilenceAndAnyOtherVolumeIsNot() {
        #expect(OutputReading(volumes: [0]).isSilent)
        #expect(OutputReading(volumes: [0, 0]).isSilent)
        #expect(OutputReading(volumes: [0, 0.4]).isSilent == false)
        #expect(OutputReading(mutes: [false], volumes: [0.5]).isSilent == false)
        #expect(OutputReading(mutes: [false], volumes: [0]).isSilent)
        #expect(OutputReading(mutes: [true], volumes: [0.5]).isSilent)
    }

    @Test func aDeviceWithNoMuteOrVolumeControlCannotBeReadSoItPlays() {
        #expect(OutputReading().isSilent == false)
    }

    @Test func readingTheRealOutputNeverCrashes() {
        _ = SystemOutput.isMuted()
    }
}
