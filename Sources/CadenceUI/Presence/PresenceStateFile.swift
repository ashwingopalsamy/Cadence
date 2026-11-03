import CadenceCore
import Foundation

/// The presence machine on disk, in `state/presence-machine.json` (docs/SPEC.md sections 7.4 and 8.4).
///
/// The app saves it after every event, so a crash leaves the open span and its last input behind. The next launch
/// hands it back to `PresenceEngine`, which closes that span at its last input instead of losing it.
struct PresenceStateFile {
    static let name = "presence-machine.json"
    static let version = 1
    /// The file is a few hundred bytes; anything much bigger is not ours.
    static let sizeLimit = 64 * 1024

    let url: URL

    init(roots: FileRoots) {
        url = roots.state.appendingPathComponent(Self.name)
    }

    enum Loaded: Equatable {
        /// No file: a first run, or a state that was cleared.
        case none
        case machine(PresenceMachine)
        /// A file that is not ours or not readable now. The machine starts fresh and the next event saves a new one.
        case unreadable
    }

    private struct Saved: Codable {
        var v: Int
        var machine: PresenceMachine
    }

    func load() -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let bytes = PrivateFile.readOwned(url, limit: Self.sizeLimit),
            let saved = try? JSONDecoder().decode(Saved.self, from: Data(bytes)), saved.v == Self.version
        else { return .unreadable }
        return .machine(saved.machine)
    }

    func save(_ machine: PresenceMachine) throws(CadenceError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(Saved(v: Self.version, machine: machine)) else {
            throw .io("cannot encode the presence state")
        }
        try PrivateFile.save(Array(bytes) + [0x0A], to: url)
    }
}
