import CadenceCore
import Foundation

/// Read-only reads beyond today's model: an earlier day, and the stand-up before the seal. Each opens a fresh read-only
/// connection off the main thread, as the day loader does, and never writes. Any failure is nil.
public struct StoreReader: Sendable {
    public let location: StoreLocation
    public let clock: any Clock

    public init(location: StoreLocation, clock: any Clock) {
        self.location = location
        self.clock = clock
    }

    /// Everything the surfaces read about `day`, in one read transaction so the parts agree.
    public func context(on day: LocalDate) async -> DayContext? {
        let clock = clock
        return await read { journal, store throws(CadenceError) in
            try store.transactRead { () throws(CadenceError) -> DayContext in try journal.dayContext(on: day, at: clock.now()) }
        }
    }

    /// The stand-up without its witness code: the seal adds the code.
    public func standup(on day: LocalDate) async -> String? {
        await read { journal, _ throws(CadenceError) in try journal.standupText(day) }
    }

    private func read<T: Sendable>(_ body: @escaping @Sendable (Journal, SQLiteStore) throws(CadenceError) -> T) async -> T? {
        guard case .found(let roots) = location else { return nil }
        let clock = clock
        return await Task.detached(priority: .userInitiated) { () -> T? in
            do throws(CadenceError) {
                let config = try ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0
                let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
                let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, readOnly: true)
                let journal = try Journal(store: store, config: config, clock: clock, ids: ids, actor: .app, writesGenesis: false)
                return try body(journal, store)
            } catch {
                return nil
            }
        }.value
    }
}
