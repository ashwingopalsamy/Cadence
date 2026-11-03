// The Recap hub and every frame of the weekly recap (T4.6), built from the October ACME demo seeded into a throwaway
// store and read on Sat 31 Oct, so the last full week is Week 43. Shared by `make token-sheet` and the snapshot suite.
import CadenceCore
import Foundation

public enum RecapSpecimens {
    /// Seeds the demo into a temporary store and reads the recaps from it the way the app does.
    public static func seeded() throws -> RecapHub {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-recap-sheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let roots = FileRoots(home: folder)
        try ConfigStore.save(DemoSeed.config(), to: roots.config)
        let clock = ManualClock(Timestamp.parse(DemoSeed.startInstant)!)
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1))
        let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
        let journal = try Journal(store: store, config: DemoSeed.config(), clock: clock, ids: ids)
        try DemoSeed.seed(into: journal, clock: clock)
        clock.set(Timestamp.parse("2026-10-31T06:30:00Z")!)
        let loader = RecapStoreLoader(location: .found(roots), clock: clock)
        guard case .loaded(let hub) = loader.load(oneOnOne: LocalDate("2026-10-15")) else {
            throw CadenceError.integrity("recap sheet: the seeded store did not load")
        }
        return hub
    }
}

/// Hands the sheet's hub to the model, so the hub is drawn by the same view the app uses.
public struct FixedRecaps: RecapLoading {
    public let hub: RecapHub
    public init(hub: RecapHub) { self.hub = hub }
    public func load(oneOnOne: LocalDate?) -> RecapLoad { .loaded(hub) }
}
