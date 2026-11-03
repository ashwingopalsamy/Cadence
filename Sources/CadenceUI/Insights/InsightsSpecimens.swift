// Insights (docs/SPEC.md section 5.4) read from the October demo seed in a throwaway store: the month as of Thursday
// 29 October, and the same store as of Friday 9 October, when there is too little data for patterns. Shared by
// `make token-sheet` and the snapshot suite.
import CadenceCore
import Foundation

@MainActor
public struct InsightsSpecimens {
    public let month: InsightsModel
    public let forming: InsightsModel

    /// The seed written into a fresh store in `folder`, read at two moments. Nil when anything fails. The models read
    /// the store again when asked to refresh, so the folder stays until its owner removes it.
    public static func make(in folder: URL) -> InsightsSpecimens? {
        try? FileManager.default.removeItem(at: folder)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
            let start = Timestamp.parse(DemoSeed.startInstant),
            let thursday = Timestamp.parse("2026-10-29T13:30:00Z"),
            let friday = Timestamp.parse("2026-10-09T06:30:00Z")
        else { return nil }
        let roots = FileRoots(home: folder)
        do {
            try ConfigStore.save(DemoSeed.config(), to: roots.config)
            let clock = ManualClock(start)
            let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1))
            let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
            let journal = try Journal(store: store, config: DemoSeed.config(), clock: clock, ids: ids)
            try DemoSeed.seed(into: journal, clock: clock)
        } catch {
            return nil
        }
        func model(at instant: Date) -> InsightsModel? {
            let loader = InsightsStoreLoader(location: .found(roots), clock: ManualClock(instant))
            guard case .loaded(let data) = loader.load(.month) else { return nil }
            return InsightsModel(loader: loader, range: .month, initial: data)
        }
        guard let month = model(at: thursday), let forming = model(at: friday) else { return nil }
        return InsightsSpecimens(month: month, forming: forming)
    }
}
