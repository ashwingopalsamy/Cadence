// The sounds that mark moments the store reports rather than a button (docs/SPEC.md section 5.6): the day starting and
// an agent logging work. Each plays once per moment, never for what was already there when the app opened.
import CadenceCore
import Foundation
import CadenceUI
import Observation

@MainActor
final class SoundCues {
    private let model: DayModel
    private let sounds: CadenceSoundPlayer
    private var started: (day: LocalDate, at: Date?)?
    private var agentEntries: Set<String>?

    init(model: DayModel, sounds: CadenceSoundPlayer) {
        self.model = model
        self.sounds = sounds
        follow()
    }

    private func follow() {
        withObservationTracking {
            _ = model.load
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.heard()
                self?.follow()
            }
        }
        heard()
    }

    private func heard() {
        guard let state = model.state else { return }
        let agents = Set(state.context?.found.filter { $0.origin == .agent }.map(\.id) ?? [])
        if let previous = started, previous.day == state.day, previous.at == nil, state.startedAt != nil {
            sounds.play(.dayStart)
        }
        if let known = agentEntries, !agents.subtracting(known).isEmpty {
            sounds.play(.agentLogged)
        }
        started = (state.day, state.startedAt)
        agentEntries = agents
    }
}
