// The Proof section (docs/SPEC.md sections 4.6 and 12) against the October demo: the file exported and checked, and a
// hand-edited file that fails Check a file. The demo is seeded into a temporary home that is removed once the states
// are read, and every file goes to that home, never into the repository. Shared by `make token-sheet` and the snapshot
// suite.
import CadenceCore
import Foundation

@MainActor
public enum ProofSpecimens {
    public struct Specimen: Identifiable {
        public let id: String
        public let title: String
        public let model: ProofModel
    }

    /// Fri 30 Oct 2026, 09:12 in Kolkata: the morning after the demo's last sealed day.
    struct FixedClock: Clock {
        func now() -> Date { Timestamp.parse("2026-10-30T03:42:00Z")! }
    }

    public static func make() -> [Specimen] {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-proof-sheet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            let roots = FileRoots(home: home)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try ConfigStore.save(DemoSeed.config(), to: roots.config)
            let clock = ManualClock(Timestamp.parse(DemoSeed.startInstant)!)
            let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1))
            let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
            try DemoSeed.seed(into: try Journal(store: store, config: DemoSeed.config(), clock: clock, ids: ids), clock: clock)

            let reader = ProofReader(location: .found(roots), clock: FixedClock())
            let load = reader.load(preset: .month, custom: nil)
            guard case .loaded(let snapshot) = load else { return [] }
            let exports = home.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            let exported = exports.appendingPathComponent(snapshot.range.fileName)
            let ok = reader.export(snapshot.range, to: exported)

            // The same file with one event's actor changed by hand.
            guard case .object(var root) = try JSONParser.parse(bytes: Array(try Data(contentsOf: exported))),
                case .object(var chain)? = root["chain"], case .array(var events)? = chain["events"], events.count > 213,
                case .object(var event) = events[213]
            else { return [] }
            event["actor"] = .string(event["actor"]?.stringValue == "app" ? "cli" : "app")
            events[213] = .object(event)
            chain["events"] = .array(events)
            root["chain"] = .object(chain)
            let tampered = exports.appendingPathComponent("october.cadence-proof.json")
            try Data(try CanonicalJSON.bytes(.object(root))).write(to: tampered)
            let bad = ProofReader.check(tampered)

            return [
                Specimen(id: "ok", title: "Exported and checked", model: ProofModel(reader: reader, preset: .month, load: load, outcome: ok)),
                Specimen(id: "bad", title: "Check a file, the file was edited", model: ProofModel(reader: reader, preset: .month, load: load, outcome: bad)),
            ]
        } catch {
            FileHandle.standardError.write(Data("proof sheet: \(error)\n".utf8))
            return []
        }
    }
}
