import CadenceCore
import Dispatch
import Foundation
import Observation

public enum RecapLoad: Sendable, Equatable {
    case loading
    case loaded(RecapHub)
    case failed(StoreFailure)
}

/// Reads the recaps from wherever the store is. A read blocks on the disk, so the model calls it off the main thread.
public protocol RecapLoading: Sendable {
    /// `.loaded` or `.failed`, never `.loading`. `oneOnOne` is the day of the last 1:1; nil picks the default.
    func load(oneOnOne: LocalDate?) -> RecapLoad
}

/// Reads every recap through `Journal` on a fresh read-only connection, in one read transaction, as `DayStoreLoader`
/// reads the day: it never writes, never migrates and never tries another location.
public struct RecapStoreLoader: RecapLoading {
    public let location: StoreLocation
    public let clock: any Clock

    public init(location: StoreLocation, clock: any Clock) {
        self.location = location
        self.clock = clock
    }

    public func load(oneOnOne: LocalDate?) -> RecapLoad {
        let roots: FileRoots
        switch location {
        case .found(let found): roots = found
        case .failed(let failure): return .failed(failure)
        }
        do {
            return .loaded(try read(roots, oneOnOne: oneOnOne))
        } catch {
            return .failed(StoreFailure(error))
        }
    }

    private func read(_ roots: FileRoots, oneOnOne: LocalDate?) throws(CadenceError) -> RecapHub {
        guard FileManager.default.fileExists(atPath: roots.database.path) else {
            throw .notFound(String(localized: "There is no cadence.db in \(roots.home.path)"))
        }
        let config = try ConfigStore.load(from: roots.config, fallbackZone: TimeZone.current.identifier).0
        let ids = ULIDGenerator(clock: clock, random: SystemRandomSource())
        let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, readOnly: true)
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids, actor: .app, writesGenesis: false)
        let today = journal.today()
        // One snapshot, so every recap reads the same ledger even while another process writes.
        return try store.transactRead { () throws(CadenceError) -> RecapHub in
            try RecapBuilder.hub(journal, today: today, oneOnOne: oneOnOne)
        }
    }
}

/// The Recap section's recaps, published on the main actor. Reads run on a background queue; requests made while
/// one runs collapse into one more read after it, so the last state published is read after the last request.
@MainActor @Observable
public final class RecapModel {
    public private(set) var load: RecapLoad = .loading
    /// The chosen day of the last 1:1, or nil for the default.
    public private(set) var oneOnOne: LocalDate?

    @ObservationIgnored private let loader: any RecapLoading
    @ObservationIgnored private let queue = DispatchQueue(label: "in.ashwingopalsamy.cadence.recap-model", qos: .userInitiated)
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var requestedAgain = false

    public init(loader: any RecapLoading) {
        self.loader = loader
    }

    public var hub: RecapHub? {
        if case .loaded(let hub) = load { return hub }
        return nil
    }

    public var failure: StoreFailure? {
        if case .failed(let failure) = load { return failure }
        return nil
    }

    /// Reads again. Returns at once.
    public func reload() {
        if reading {
            requestedAgain = true
            return
        }
        reading = true
        Task { await publish() }
    }

    /// Sets the day of the last 1:1 and reads again.
    public func choose(oneOnOne date: LocalDate) {
        oneOnOne = date
        reload()
    }

    private func publish() async {
        repeat {
            requestedAgain = false
            load = await read(oneOnOne)
        } while requestedAgain
        reading = false
    }

    private func read(_ date: LocalDate?) async -> RecapLoad {
        let loader = loader
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: loader.load(oneOnOne: date)) }
        }
    }
}
